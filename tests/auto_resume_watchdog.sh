#!/usr/bin/env bash
# Hermetic drill for the auto-resume watchdog (R39 brief, hermetic behavior gate). Everything runs
# under a scratch root with fake tmux/systemctl/curl/uuidgen on PATH: no real claude, no real tmux
# server, no user units, no network, no repository runtime state. The fakes RECORD every
# invocation, so assertions are about what the watchdog actually did, not what it printed.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$(pwd)

fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ---- scratch repo root ---------------------------------------------------------------------------
R="$tmp/root"
mkdir -p "$R/scripts/lib/usage-framings" "$R/.orchestrator/state"
cp -p scripts/watchdog scripts/intake scripts/install-watchdog "$R/scripts/"
cp -p scripts/lib/watchdog-resume-prompt.txt "$R/scripts/lib/"
LEDGER="$R/.orchestrator/REQUEST-LEDGER.md"
HEADER='| id | date | request | lane | plan-ref | status | completion-evidence |'

# ---- fakes ---------------------------------------------------------------------------------------
F="$tmp/fakes"; TS="$tmp/tmux-state"
mkdir -p "$F" "$TS/sessions"

cat > "$F/tmux" <<'FAKE'
#!/usr/bin/env bash
S="$FAKE_TMUX_STATE"
echo "tmux $*" >> "$S/invocations.log"
cmd=$1; shift
name=""; args=()
while (($#)); do
  case "$1" in
    -t|-s) name=$2; shift 2 ;;
    -d|-o|-p) shift ;;
    -c|-x|-y) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
case "$cmd" in
  has-session)    [ -e "$S/sessions/$name" ] ;;
  new-session)    touch "$S/sessions/$name"; echo bash > "$S/sessions/$name.cmd" ;;
  send-keys)      printf '%s\n' "${args[*]}" >> "$S/sessions/$name.keys"
                  echo claude > "$S/sessions/$name.cmd" ;;
  display-message) cat "$S/sessions/$name.cmd" 2>/dev/null || echo bash ;;
  pipe-pane)      : ;;
  kill-session)   rm -f "$S/sessions/$name" "$S/sessions/$name."* ;;
  *) exit 0 ;;
esac
FAKE

cat > "$F/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_TMUX_STATE/invocations.log"
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "is-active" ]; then
  grep -qx "${3:-}" "$FAKE_ACTIVE_UNITS" 2>/dev/null
  exit $?
fi
exit 0
FAKE

cat > "$F/curl" <<'FAKE'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_CURL_LOG"
exit "${FAKE_CURL_EXIT:-0}"
FAKE

cat > "$F/uuidgen" <<'FAKE'
#!/usr/bin/env bash
n=$(cat "$FAKE_UUID_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FAKE_UUID_COUNT"
printf '00000000-0000-4000-8000-%012d\n' "$n"
FAKE

cat > "$F/loginctl" <<'FAKE'
#!/usr/bin/env bash
echo "Linger=yes"
FAKE
chmod +x "$F"/*

export FAKE_TMUX_STATE="$TS" FAKE_ACTIVE_UNITS="$tmp/active-units" FAKE_CURL_LOG="$tmp/curl.log" FAKE_UUID_COUNT="$tmp/uuid-count"

WDIR="$R/.orchestrator/watchdog"
run_wd() { # run one watchdog check in the sandbox
  PATH="$F:$PATH" ORCH_ROOT="$R" ORCH_WATCHDOG_DIR="$WDIR" ORCH_TMUX_SESSION=orch-auto \
    bash "$R/scripts/watchdog" "${@:-check}" >> "$tmp/wd.log" 2>&1
}
reset() { # fresh state between scenarios
  rm -rf "$WDIR" "$TS" "$R/.orchestrator/HALT" "$R/.orchestrator/state"
  mkdir -p "$TS/sessions" "$R/.orchestrator/state"
  rm -f "$FAKE_CURL_LOG" "$FAKE_ACTIVE_UNITS" "$FAKE_UUID_COUNT" "$LEDGER.lock"
  printf '%s\n' "$HEADER" > "$LEDGER"
  unset FAKE_CURL_EXIT || true
}
open_row() { (cd "$R" && scripts/intake -g "${1:-drill goal}" -d "done when the drill criterion holds" >/dev/null); }
keys() { cat "$TS/sessions/orch-auto.keys" 2>/dev/null || true; }
invoked() { # count of a given tmux subcommand; a missing log means zero calls, not a broken count
  [ -e "$TS/invocations.log" ] || { echo 0; return; }
  grep -c "^tmux $1" "$TS/invocations.log" || true
}

echo "== W0: tracked resume prompt carries every binding instruction"
P="scripts/lib/watchdog-resume-prompt.txt"
for phrase in "HALT" "dispatch reconcile" "CLAUDE.md" "scripts/intake" "NEVER touch main" "NEVER create approval files" "heartbeat" "observation rows"; do
  grep -qF "$phrase" "$P" && ok "prompt mentions: $phrase" || bad "prompt is missing: $phrase"
done

echo "== W1 (a): pending work + no session -> exactly one session, correct launch"
reset; open_row
run_wd
[ "$(invoked new-session)" = "1" ] && ok "created exactly one session" || bad "new-session count: $(invoked new-session)"
grep -q -- "--session-id 00000000-0000-4000-8000-000000000001" <(keys) && ok "launched with a chosen --session-id" || bad "no --session-id in launch"
grep -q -- "--dangerously-skip-permissions" <(keys) && ok "permissions skipped (owner-accepted posture)" || bad "missing permission flag"
grep -q "watchdog-resume-prompt" <(keys) && ok "tracked prompt injected" || bad "prompt not injected"
grep -qE '(^| )-p( |$)' <(keys) && bad "print mode leaked into the launch (R23!)" || ok "no -p anywhere in the launch"
grep -q "^tmux pipe-pane" "$TS/invocations.log" && ok "pane transcript piping enabled" || bad "pipe-pane never set up"
[ -s "$WDIR/last-run" ] && ok "last-run recorded" || bad "last-run missing"

echo "== W2: no pending work -> strict no-op, dead idle pane not restarted"
reset
run_wd
[ -z "$(keys)" ] && [ "$(invoked new-session)" = "0" ] && ok "idle: no session, no keys" || bad "idle run acted"
mkdir -p "$TS/sessions"; touch "$TS/sessions/orch-auto"; echo bash > "$TS/sessions/orch-auto.cmd"
run_wd
[ -z "$(keys)" ] && ok "dead idle pane left dead" || bad "dead idle pane was restarted"

echo "== W3 (b): dead pane + pending + valid recorded id -> one --resume of THAT id"
reset; open_row
run_wd                                   # launch (id ...0001 recorded)
echo bash > "$TS/sessions/orch-auto.cmd" # claude died
run_wd
[ "$(grep -c -- '--resume 00000000-0000-4000-8000-000000000001' <(keys))" = "1" ] && ok "one ID-specific --resume" || bad "resume wrong or duplicated: $(keys)"
grep -q -- '--continue' <(keys) && bad "--continue used despite a valid id" || ok "--continue not used"
run_wd                                   # now alive again (fake send-keys marks pane live)
[ "$(grep -c -- '--resume' <(keys))" = "1" ] && ok "live pane not re-prompted" || bad "live pane got extra input"

echo "== W4 (b): dead pane + corrupt recorded id -> --continue fallback + alert, never silent"
reset; open_row
run_wd
echo "not-a-uuid" > "$WDIR/session-id"
echo bash > "$TS/sessions/orch-auto.cmd"
run_wd
grep -q -- '--continue' <(keys) && ok "fell back to --continue" || bad "no fallback launch"
[ -e "$WDIR/ALERT-fallback-continue" ] && ok "fallback raised an alert incident" || bad "silent fallback"

echo "== W5 (c): approved framing arms a wait; no input before the deadline; observe mode after it"
reset; open_row
printf 's/.*DRILL-LIMIT-RESET-EPOCH ([0-9]+).*/\\1/p\n' > "$R/scripts/lib/usage-framings/drill.sed"
run_wd
future=$(( $(date +%s) + 3600 ))
printf 'DRILL-LIMIT-RESET-EPOCH %s\n' "$future" >> "$WDIR/transcript.log"
n_before=$(keys | wc -l)
run_wd
read -r wait_epoch wait_gen < "$WDIR/usage-wait" 2>/dev/null || wait_epoch=""
[ "$wait_epoch" = "$future" ] && ok "wait recorded with the framed epoch" || bad "usage-wait missing/wrong"
[ "$(keys | wc -l)" = "$n_before" ] && ok "no input sent before the deadline" || bad "input sent during the wait"
echo "$(( $(date +%s) - 60 )) $wait_gen" > "$WDIR/usage-wait"   # deadline passes
run_wd
[ -e "$WDIR/ALERT-usage-would-retry" ] && ok "observe mode recorded a would-retry" || bad "no would-retry record"
[ "$(keys | wc -l)" = "$n_before" ] && ok "observe mode sent nothing" || bad "observe mode sent input"
[ ! -e "$WDIR/usage-wait" ] && ok "expired wait cleared" || bad "wait not cleared"

echo "== W6 (c): active mode sends exactly one retry after the deadline"
mkdir -p "$WDIR"; printf 'USAGE_RETRY_MODE=active\n' > "$WDIR/env"; chmod 600 "$WDIR/env"
gen=$(cat "$WDIR/generation")
echo "$(( $(date +%s) - 60 )) $gen" > "$WDIR/usage-wait"
n_before=$(keys | wc -l)
run_wd
[ "$(keys | wc -l)" = "$((n_before + 1))" ] && ok "exactly one retry sent" || bad "retry count wrong"
keys | tail -1 | grep -q "usage window has reset" && ok "retry is the reset prompt" || bad "unexpected retry content"
run_wd
[ "$(keys | wc -l)" = "$((n_before + 1))" ] && ok "retry not repeated" || bad "retry repeated"

echo "== W7 (c): a stale wait from an older pane generation is discarded, not obeyed"
gen=$(cat "$WDIR/generation")
echo "$(( $(date +%s) - 60 )) $(( gen - 1 ))" > "$WDIR/usage-wait"
n_before=$(keys | wc -l)
run_wd
[ ! -e "$WDIR/usage-wait" ] && [ "$(keys | wc -l)" = "$n_before" ] && ok "old-generation wait dropped silently" || bad "old-generation wait acted on"

echo "== W8 (c): spoof text without an approved framing -> one incident, retry disabled, recovery unaffected"
reset; open_row
run_wd
printf 'The model says: usage limit reached, resets at 5pm somehow\n' >> "$WDIR/transcript.log"
run_wd
[ ! -e "$WDIR/usage-wait" ] && ok "spoof did not arm a wait" || bad "spoof armed a wait"
[ -e "$WDIR/ALERT-usage-unknown" ] && ok "unknown-framing incident raised" || bad "no incident for limit-like text"
run_wd
[ "$(grep -c '^ts=' "$WDIR/ALERT-usage-unknown")" = "1" ] && ok "one incident per generation" || bad "incident duplicated"
echo bash > "$TS/sessions/orch-auto.cmd"
run_wd
grep -q -- '--resume' <(keys) && ok "dead-pane recovery survived the classifier failure" || bad "classifier failure blocked recovery"

echo "== W9: replay resistance — consumed transcript bytes never re-arm anything"
reset; open_row
printf 's/.*DRILL-LIMIT-RESET-EPOCH ([0-9]+).*/\\1/p\n' > "$R/scripts/lib/usage-framings/drill.sed"
run_wd
printf 'DRILL-LIMIT-RESET-EPOCH %s\n' "$(( $(date +%s) + 3600 ))" >> "$WDIR/transcript.log"
run_wd
rm -f "$WDIR/usage-wait"
run_wd
[ ! -e "$WDIR/usage-wait" ] && ok "already-consumed framing did not re-arm the wait" || bad "replay re-armed the wait"

echo "== W10 (d): idle alert — local record first, delivery, dedup, retry-on-failure, heartbeat"
reset; open_row
run_wd
printf 'ALERT_URL=https://alerts.invalid/topic\nALERT_TOKEN=drill-token\n' >> "$WDIR/env" 2>/dev/null || { mkdir -p "$WDIR"; printf 'ALERT_URL=https://alerts.invalid/topic\n' > "$WDIR/env"; }
echo "$(( $(date +%s) - 30000 ))" > "$WDIR/last-run"
run_wd
[ -e "$WDIR/ALERT-idle" ] && ok "local ALERT-idle record written" || bad "no local idle record"
[ "$(grep -c '^curl ' "$FAKE_CURL_LOG" 2>/dev/null)" = "1" ] && ok "delivery attempted once" || bad "curl count wrong"
grep -q 'drill goal' "$FAKE_CURL_LOG" && bad "payload leaked request text" || ok "payload sanitized (no request text)"
grep -q 'open_rows=R1' "$FAKE_CURL_LOG" && ok "payload names the intake id only" || bad "payload missing intake id"
run_wd
[ "$(grep -c '^curl ' "$FAKE_CURL_LOG")" = "1" ] && ok "delivered alert not re-sent within the interval" || bad "alert spammed"
rm -f "$WDIR/ALERT-idle" "$FAKE_CURL_LOG"
export FAKE_CURL_EXIT=22
run_wd; run_wd
[ "$(grep -c '^curl ' "$FAKE_CURL_LOG")" = "2" ] && ok "failed delivery retries next tick" || bad "failed delivery did not retry"
[ -e "$WDIR/ALERT-idle" ] && grep -q '^sent=' "$WDIR/ALERT-idle" && bad "failed delivery marked sent" || ok "failed delivery not marked sent"
unset FAKE_CURL_EXIT
run_wd heartbeat
run_wd
grep -q '^sent=' "$WDIR/ALERT-idle" 2>/dev/null || rm -f "$WDIR/ALERT-idle"   # heartbeat is fresh; a new alert must NOT appear
[ ! -e "$WDIR/ALERT-idle" ] || grep -q '^sent=' "$WDIR/ALERT-idle" || bad "fresh heartbeat did not suppress the idle alert"
[ -s "$WDIR/activity" ] && ok "heartbeat wrote activity" || bad "heartbeat wrote nothing"

echo "== W11: no ALERT_URL -> local record and journal only, no delivery attempt"
reset; open_row
run_wd
echo "$(( $(date +%s) - 30000 ))" > "$WDIR/last-run"
run_wd
[ -e "$WDIR/ALERT-idle" ] && ok "local record without a channel" || bad "no local record"
[ ! -e "$FAKE_CURL_LOG" ] && ok "no delivery attempted without a channel" || bad "curl called with no ALERT_URL"

echo "== W12 (e): HALT is a strict no-op — nothing created, nothing sent, no alert"
reset; open_row
touch "$R/.orchestrator/HALT"
run_wd
[ ! -d "$WDIR" ] && ok "HALT: state dir not even created" || bad "HALT still created state"
[ "$(invoked new-session)" = "0" ] && [ -z "$(keys)" ] && ok "HALT: no tmux action" || bad "HALT acted on tmux"
[ ! -e "$FAKE_CURL_LOG" ] && ok "HALT: no alert delivery" || bad "HALT sent an alert"
run_wd heartbeat
[ ! -e "$WDIR/activity" ] && ok "HALT: heartbeat refused" || bad "HALT: heartbeat wrote"

echo "== W13: INDETERMINATE ledger -> alert, and NOTHING is launched or prompted"
reset
printf '%s\n' "$HEADER" "| R1 | 2026-07-14 | broken row with | six cells | open |" > "$LEDGER"
run_wd
[ "$(invoked new-session)" = "0" ] && ok "indeterminate: no launch" || bad "indeterminate launched"
[ -e "$WDIR/ALERT-intake-indeterminate" ] && ok "indeterminate: alert raised" || bad "indeterminate: silent"

echo "== W14: a genuinely live attempt counts as pending even with an idle ledger; stale state does not"
reset
cat > "$R/.orchestrator/state/SPEC-099.json" <<'EOF'
{ "status": "running", "attempt_id": "SPEC-099-1" }
EOF
run_wd
[ "$(invoked new-session)" = "0" ] && ok "stale running-state without an active unit: no launch" || bad "stale state launched"
echo "codex-SPEC-099-1" > "$FAKE_ACTIVE_UNITS"
run_wd
[ "$(invoked new-session)" = "1" ] && ok "live attempt: session launched to supervise it" || bad "live attempt ignored"

echo "== W15: single flight — a held lock makes the second check a successful no-op"
reset; open_row
mkdir -p "$WDIR"; chmod 700 "$WDIR"
(
  exec 9>>"$WDIR/lock"; flock 9
  run_wd
) 9>>"$WDIR/lock"
# the subshell HOLDS the lock while run_wd executes inside it
[ "$(invoked new-session)" = "0" ] && ok "second flight skipped under a held lock" || bad "lock did not exclude"
run_wd
[ "$(invoked new-session)" = "1" ] && ok "after release the work happens once" || bad "post-release run wrong"

echo "== W16: installer renders units into a fake HOME, idempotently; uninstall removes only its own"
reset
IH="$tmp/fakehome"; mkdir -p "$IH/.config/systemd/user"
printf '%s\n' "someone else's unit" > "$IH/.config/systemd/user/other.timer"
PATH="$F:$PATH" HOME="$IH" ORCH_ROOT="$R" ORCH_WATCHDOG_DIR="$WDIR" bash "$R/scripts/install-watchdog" install >> "$tmp/wd.log" 2>&1 \
  && ok "install succeeded" || bad "install failed: $(tail -3 "$tmp/wd.log")"
[ -e "$IH/.config/systemd/user/orchestrator-watchdog.timer" ] && ok "timer rendered" || bad "timer missing"
grep -q "ExecStart=$R/scripts/watchdog check" "$IH/.config/systemd/user/orchestrator-watchdog.service" && ok "service points at this checkout" || bad "service ExecStart wrong"
[ "$(stat -c %a "$WDIR/env")" = "600" ] && ok "env rendered mode 600" || bad "env mode wrong"
grep -q '^USAGE_RETRY_MODE=observe' "$WDIR/env" && ok "default mode is observe" || bad "default mode not observe"
PATH="$F:$PATH" HOME="$IH" ORCH_ROOT="$R" ORCH_WATCHDOG_DIR="$WDIR" bash "$R/scripts/install-watchdog" install >> "$tmp/wd.log" 2>&1 \
  && ok "re-install is idempotent" || bad "re-install failed"
PATH="$F:$PATH" HOME="$IH" ORCH_ROOT="$R" ORCH_WATCHDOG_DIR="$WDIR" bash "$R/scripts/install-watchdog" uninstall >> "$tmp/wd.log" 2>&1
[ ! -e "$IH/.config/systemd/user/orchestrator-watchdog.timer" ] && ok "uninstall removed its units" || bad "uninstall left units"
[ -e "$IH/.config/systemd/user/other.timer" ] && ok "uninstall left the foreign unit alone" || bad "uninstall deleted a foreign unit"

echo "== W17: zero real contact — every tmux/systemctl call went through the fakes"
[ -s "$TS/invocations.log" ] && ok "fake invocation log is non-empty (fakes were in the path)" || bad "fakes never invoked — test is not testing"

if [ "$fails" -eq 0 ]; then echo "PASS auto_resume_watchdog.sh"; else echo "FAIL auto_resume_watchdog.sh"; exit 1; fi
