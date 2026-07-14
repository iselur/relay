#!/usr/bin/env bash
# Hermetic drill for the auto-resume watchdog (R39 brief, hermetic behavior gate). Everything runs
# under a scratch root with fake claude/tmux/systemctl/curl/uuidgen/loginctl on PATH: no real
# claude, no real tmux server, no user units, no network, no repository runtime state. The fakes
# RECORD every invocation, so assertions are about what the watchdog actually did. The fake claude
# answers --version only and FAILS the run if anything ever truly executes it beyond that.
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
[ "$cmd" = "${FAKE_TMUX_FAIL:-}" ] && exit 1
# HALT-injection hook DURING a tmux action (round-3 review: HALT after new-session, before send-keys)
[ "$cmd" = "${FAKE_TMUX_MAKE_HALT_ON:-}" ] && [ -n "${FAKE_TMUX_HALT_PATH:-}" ] && touch "$FAKE_TMUX_HALT_PATH"
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

cat > "$F/claude" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "${FAKE_CLAUDE_VERSION:-9.9.9 (Fake)}"; exit 0; fi
echo "HERMETIC BREACH: claude executed with: $*" >> "$FAKE_TMUX_STATE/breach.log"
exit 97
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
# FAKE_UUID_MAKE_HALT: deterministic HALT-injection hook — uuidgen is the external command the
# watchdog runs between its entry guard and its first mutation (round-2 review, critical 2).
[ -n "${FAKE_UUID_MAKE_HALT:-}" ] && touch "$FAKE_UUID_MAKE_HALT"
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
run_wd() { # run one watchdog invocation in the sandbox
  PATH="$F:$PATH" ORCH_ROOT="$R" ORCH_WATCHDOG_DIR="$WDIR" ORCH_TMUX_SESSION=orch-auto \
    bash "$R/scripts/watchdog" "${@:-check}" >> "$tmp/wd.log" 2>&1
}
reset() { # fresh state between scenarios
  rm -rf "$WDIR" "$TS" "$R/.orchestrator/HALT" "$R/.orchestrator/state" "$R/scripts/lib/usage-framings"
  mkdir -p "$TS/sessions" "$R/.orchestrator/state" "$R/scripts/lib/usage-framings"
  rm -f "$FAKE_CURL_LOG" "$FAKE_ACTIVE_UNITS" "$FAKE_UUID_COUNT" "$LEDGER.lock"
  printf '%s\n' "$HEADER" > "$LEDGER"
  unset FAKE_CURL_EXIT FAKE_TMUX_FAIL FAKE_CLAUDE_VERSION 2>/dev/null || true
}
open_row() { (cd "$R" && scripts/intake -g "${1:-drill goal}" -d "done when the drill criterion holds" >/dev/null); }
keys() { cat "$TS/sessions/orch-auto.keys" 2>/dev/null || true; }
invoked() { # count of a given tmux subcommand; a missing log means zero calls, not a broken count
  [ -e "$TS/invocations.log" ] || { echo 0; return; }
  grep -c "^tmux $1" "$TS/invocations.log" || true
}
dead_pane() { echo bash > "$TS/sessions/orch-auto.cmd"; }
alert_env() { # configure a complete owner alert channel
  mkdir -p "$WDIR"
  printf 'ALERT_URL=https://alerts.invalid/topic\nALERT_TOKEN=drill-token\n' >> "$WDIR/env"
  chmod 600 "$WDIR/env"
}

echo "== W0: tracked resume prompt carries every binding instruction, in the required order"
P="scripts/lib/watchdog-resume-prompt.txt"
for phrase in "HALT" "dispatch reconcile" "CLAUDE.md" "scripts/intake" "NEVER touch main" "NEVER create approval files" "heartbeat" "observation rows"; do
  grep -qF "$phrase" "$P" && ok "prompt mentions: $phrase" || bad "prompt is missing: $phrase"
done
halt_line=$(grep -nF "HALT" "$P" | head -1 | cut -d: -f1)
rec_line=$(grep -nF "dispatch reconcile" "$P" | head -1 | cut -d: -f1)
[ -n "$halt_line" ] && [ -n "$rec_line" ] && [ "$halt_line" -lt "$rec_line" ] \
  && ok "HALT check comes before reconcile" || bad "prompt ordering wrong: HALT must precede reconcile"

echo "== W1 (a): pending work + no session -> exactly one session, exact launch line"
reset; open_row
run_wd
[ "$(invoked new-session)" = "1" ] && ok "created exactly one session" || bad "new-session count: $(invoked new-session)"
expected='claude --session-id 00000000-0000-4000-8000-000000000001 --dangerously-skip-permissions "$(cat scripts/lib/watchdog-resume-prompt.txt)" Enter'
[ "$(keys | head -1)" = "$expected" ] && ok "launch line matches the exact expected string (relative prompt path, chosen id, no -p)" \
  || bad "launch line differs: $(keys | head -1)"
grep -q "^tmux pipe-pane" "$TS/invocations.log" && ok "pane transcript piping enabled" || bad "pipe-pane never set up"
[ -s "$WDIR/last-run" ] && ok "last-run recorded" || bad "last-run missing"

echo "== W2: no pending work -> strict no-op, dead idle pane not restarted"
reset
run_wd
[ "$(invoked new-session)" = "0" ] && [ -z "$(keys)" ] && ok "idle: no session, no keys" || bad "idle run acted"
mkdir -p "$TS/sessions"; touch "$TS/sessions/orch-auto"; dead_pane
run_wd
[ -z "$(keys)" ] && ok "dead idle pane left dead" || bad "dead idle pane was restarted"

echo "== W3 (b): dead pane + pending + valid recorded id -> one --resume of THAT id"
reset; open_row
run_wd
dead_pane
run_wd
[ "$(grep -c -- '--resume 00000000-0000-4000-8000-000000000001' <(keys))" = "1" ] && ok "one ID-specific --resume" || bad "resume wrong or duplicated"
grep -q -- '--continue' <(keys) && bad "--continue used despite a valid id" || ok "--continue not used"
run_wd
[ "$(grep -c -- '--resume' <(keys))" = "1" ] && ok "live pane not re-prompted" || bad "live pane got extra input"

echo "== W4 (b): CORRUPT recorded id -> visible failure, NO relaunch of any kind"
reset; open_row
run_wd
echo "not-a-uuid" > "$WDIR/session-id"
dead_pane
n_before=$(keys | wc -l)
run_wd
[ "$(keys | wc -l)" = "$n_before" ] && ok "corrupt id: nothing relaunched" || bad "corrupt id still launched something"
[ -e "$WDIR/ALERT-corrupt-session-id" ] && ok "corrupt id raised its own alert" || bad "corrupt id failed silently"

echo "== W4b (b): LOST id (recorded, then wiped) -> same visible refusal; --continue does not exist"
reset; open_row
run_wd
rm -f "$WDIR/session-id"                       # the launcher ALWAYS records an id, so absence = lost or foreign
dead_pane
n_before=$(keys | wc -l)
run_wd
[ "$(keys | wc -l)" = "$n_before" ] && ok "lost id: nothing relaunched" || bad "lost id still launched something"
[ -e "$WDIR/ALERT-corrupt-session-id" ] && ok "lost id raised the visible alert" || bad "lost id failed silently"
grep -q -- 'claude --continue' "$R/scripts/watchdog" && bad "a claude --continue invocation still exists in the watchdog" || ok "no claude --continue invocation anywhere in the program"

echo "== W5 (c): approved framing arms a wait; no input before the deadline; observe mode after it"
reset; open_row
printf 's/.*DRILL-LIMIT-RESET-EPOCH ([0-9]+).*/\\1/p\n' > "$R/scripts/lib/usage-framings/drill.sed"
run_wd
future=$(( $(date +%s) + 3600 ))
printf 'DRILL-LIMIT-RESET-EPOCH %s\n' "$future" >> "$WDIR/transcript.log"
n_before=$(keys | wc -l)
run_wd
read -r wait_epoch wait_gen wait_fr wait_range < "$WDIR/usage-wait" 2>/dev/null || wait_epoch=""
[ "$wait_epoch" = "$future" ] && [ "$wait_fr" = "drill.sed" ] && [ -n "${wait_range:-}" ] \
  && ok "wait recorded with epoch, framing identity, and transcript range" || bad "usage-wait missing/wrong"
[ "$(keys | wc -l)" = "$n_before" ] && ok "no input sent before the deadline" || bad "input sent during the wait"
echo "$(( $(date +%s) - 60 )) $wait_gen drill.sed" > "$WDIR/usage-wait"
run_wd
[ -e "$WDIR/ALERT-usage-would-retry" ] && ok "observe mode recorded a would-retry" || bad "no would-retry record"
[ "$(keys | wc -l)" = "$n_before" ] && ok "observe mode sent nothing" || bad "observe mode sent input"
[ ! -e "$WDIR/usage-wait" ] && ok "expired wait cleared" || bad "wait not cleared"

echo "== W6 (c): active mode sends exactly one retry after the deadline"
printf 'USAGE_RETRY_MODE=active\n' > "$WDIR/env"; chmod 600 "$WDIR/env"
gen=$(cat "$WDIR/generation")
echo "$(( $(date +%s) - 60 )) $gen drill.sed" > "$WDIR/usage-wait"
n_before=$(keys | wc -l)
run_wd
[ "$(keys | wc -l)" = "$((n_before + 1))" ] && ok "exactly one retry sent" || bad "retry count wrong"
keys | tail -1 | grep -q "usage window has reset" && ok "retry is the reset prompt" || bad "unexpected retry content"
run_wd
[ "$(keys | wc -l)" = "$((n_before + 1))" ] && ok "retry not repeated" || bad "retry repeated"

echo "== W6b (c): corrupt usage-wait state is discarded, never obeyed, even in active mode"
echo "garbage not-a-number x" > "$WDIR/usage-wait"
n_before=$(keys | wc -l)
run_wd
[ "$(keys | wc -l)" = "$n_before" ] && ok "corrupt wait sent nothing" || bad "corrupt wait reached the send branch"
[ ! -e "$WDIR/usage-wait" ] && ok "corrupt wait discarded" || bad "corrupt wait kept"
[ -e "$WDIR/ALERT-usage-unknown" ] && ok "corrupt wait raised an incident" || bad "corrupt wait silent"

echo "== W7 (c): a stale wait from an older pane generation is discarded, not obeyed"
gen=$(cat "$WDIR/generation")
echo "$(( $(date +%s) - 60 )) $(( gen - 1 )) drill.sed" > "$WDIR/usage-wait"
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
dead_pane
run_wd
grep -q -- '--resume' <(keys) && ok "dead-pane recovery survived the classifier failure" || bad "classifier failure blocked recovery"

echo "== W8b (c): CLI version change with fixtures present -> one re-verification incident, nothing stops"
reset; open_row
printf 's/.*DRILL-LIMIT-RESET-EPOCH ([0-9]+).*/\\1/p\n' > "$R/scripts/lib/usage-framings/drill.sed"
run_wd
export FAKE_CLAUDE_VERSION="1.0.0 (Fake)"
printf 'some output\n' >> "$WDIR/transcript.log"; run_wd
export FAKE_CLAUDE_VERSION="2.0.0 (Fake)"
printf 'more output\n' >> "$WDIR/transcript.log"; run_wd
[ -e "$WDIR/ALERT-cli-version" ] && ok "version change raised a re-verification incident" || bad "version change unnoticed"
dead_pane; run_wd
grep -q -- '--resume' <(keys) && ok "supervision unaffected by the version incident" || bad "version incident froze recovery"
unset FAKE_CLAUDE_VERSION

echo "== W9: replay resistance — consumed bytes and external truncation never re-arm anything"
reset; open_row
printf 's/.*DRILL-LIMIT-RESET-EPOCH ([0-9]+).*/\\1/p\n' > "$R/scripts/lib/usage-framings/drill.sed"
run_wd
printf 'DRILL-LIMIT-RESET-EPOCH %s\n' "$(( $(date +%s) + 3600 ))" >> "$WDIR/transcript.log"
run_wd
rm -f "$WDIR/usage-wait"
run_wd
[ ! -e "$WDIR/usage-wait" ] && ok "already-consumed framing did not re-arm the wait" || bad "replay re-armed the wait"
echo "999999999" > "$WDIR/transcript.offset"      # offset beyond file size = external truncation
run_wd
grep -q 'shrank' "$WDIR/ALERT-usage-unknown" 2>/dev/null && ok "external truncation raised an incident" || bad "truncation silent"
[ ! -e "$WDIR/usage-wait" ] && ok "truncation armed nothing" || bad "truncation armed a wait"

echo "== W10 (d): idle alert — local record first, delivery, dedup, retry-on-failure"
reset; open_row
run_wd
alert_env
echo "$(( $(date +%s) - 30000 ))" > "$WDIR/last-run"
run_wd
[ -e "$WDIR/ALERT-idle" ] && ok "local ALERT-idle record written" || bad "no local idle record"
[ "$(grep -c '^curl ' "$FAKE_CURL_LOG" 2>/dev/null)" = "1" ] && ok "delivery attempted once" || bad "curl count wrong"
grep -q 'drill goal' "$FAKE_CURL_LOG" && bad "payload leaked request text" || ok "payload sanitized (no request text)"
grep -q 'open_rows=R1' "$FAKE_CURL_LOG" && ok "payload names the intake id only" || bad "payload missing intake id"
grep -q 'Authorization: Bearer drill-token' "$FAKE_CURL_LOG" && ok "delivery authenticated" || bad "delivery unauthenticated"
run_wd
[ "$(grep -c '^curl ' "$FAKE_CURL_LOG")" = "1" ] && ok "delivered alert not re-sent within the interval" || bad "alert spammed"
rm -f "$WDIR/ALERT-idle" "$FAKE_CURL_LOG"
export FAKE_CURL_EXIT=22
run_wd; run_wd
[ "$(grep -c '^curl ' "$FAKE_CURL_LOG")" -ge 2 ] && ok "failed delivery retries next tick" || bad "failed delivery did not retry"
grep -q '^sent=' "$WDIR/ALERT-idle" && bad "failed delivery marked sent" || ok "failed delivery not marked sent"
unset FAKE_CURL_EXIT

echo "== W10b (d): a fresh heartbeat suppresses the idle alert; real activity resets the interval"
rm -f "$WDIR/ALERT-idle" "$FAKE_CURL_LOG"
run_wd heartbeat
run_wd
[ ! -e "$WDIR/ALERT-idle" ] && ok "fresh heartbeat suppressed the idle alert" || bad "idle alert fired despite fresh activity"
[ -s "$WDIR/activity" ] && ok "heartbeat wrote activity" || bad "heartbeat wrote nothing"

echo "== W10c (d): a genuinely live attempt suppresses the idle alert"
reset; open_row
run_wd
alert_env
echo "$(( $(date +%s) - 30000 ))" > "$WDIR/last-run"
cat > "$R/.orchestrator/state/SPEC-100.json" <<'EOF'
{ "status": "running", "attempt_id": "SPEC-100-1" }
EOF
echo "codex-SPEC-100-1" > "$FAKE_ACTIVE_UNITS"
run_wd
[ ! -e "$WDIR/ALERT-idle" ] && ok "active attempt: no idle alert" || bad "idle alert fired over a live attempt"

echo "== W11: incomplete channel -> local record only, no delivery attempt"
reset; open_row
run_wd
echo "$(( $(date +%s) - 30000 ))" > "$WDIR/last-run"
run_wd
[ -e "$WDIR/ALERT-idle" ] && [ ! -e "$FAKE_CURL_LOG" ] && ok "no channel: local record, no curl" || bad "no-channel case wrong"
reset; open_row
run_wd
mkdir -p "$WDIR"; printf 'ALERT_URL=https://alerts.invalid/topic\n' >> "$WDIR/env"   # URL but NO token
echo "$(( $(date +%s) - 30000 ))" > "$WDIR/last-run"
run_wd
[ -e "$WDIR/ALERT-idle" ] && [ ! -e "$FAKE_CURL_LOG" ] && ok "URL without token: incident kept, nothing sent" || bad "unauthenticated delivery attempted"
reset; open_row
run_wd
mkdir -p "$WDIR"; printf 'ALERT_URL=http://alerts.invalid/topic\nALERT_TOKEN=t-123456\n' >> "$WDIR/env"   # not https
echo "$(( $(date +%s) - 30000 ))" > "$WDIR/last-run"
run_wd
[ ! -e "$FAKE_CURL_LOG" ] && ok "non-https URL: delivery disabled" || bad "plaintext delivery attempted"

echo "== W11b: undelivered non-idle incidents are swept for delivery on later ticks"
reset; open_row
run_wd
alert_env
echo "not-a-uuid" > "$WDIR/session-id"; dead_pane
export FAKE_CURL_EXIT=22
run_wd                                            # corrupt-session-id raised; delivery fails
unset FAKE_CURL_EXIT
run_wd                                            # refusal repeats, but only the sweep delivers
grep -q '^sent=' "$WDIR/ALERT-corrupt-session-id" && ok "sweep delivered the stranded incident" || bad "stranded incident never delivered"

echo "== W12 (e): HALT is a strict no-op — nothing created, nothing sent, no alert"
reset; open_row
touch "$R/.orchestrator/HALT"
run_wd
[ ! -d "$WDIR" ] && ok "HALT: state dir not even created" || bad "HALT still created state"
[ "$(invoked new-session)" = "0" ] && [ -z "$(keys)" ] && ok "HALT: no tmux action" || bad "HALT acted on tmux"
[ ! -e "$FAKE_CURL_LOG" ] && ok "HALT: no alert delivery" || bad "HALT sent an alert"
run_wd heartbeat
[ ! -e "$WDIR/activity" ] && ok "HALT: heartbeat refused" || bad "HALT: heartbeat wrote"

echo "== W12b (e): HALT injected DURING the launch (via the uuidgen hook) -> no session, no state"
reset; open_row
export FAKE_UUID_MAKE_HALT="$R/.orchestrator/HALT"
run_wd
unset FAKE_UUID_MAKE_HALT
[ "$(invoked new-session)" = "0" ] && ok "mid-launch HALT: no session created" || bad "mid-launch HALT still created a session"
[ ! -e "$WDIR/session-id" ] && [ ! -e "$WDIR/generation" ] && ok "mid-launch HALT: no state mutated" || bad "mid-launch HALT mutated state"
[ -z "$(keys)" ] && ok "mid-launch HALT: nothing typed anywhere" || bad "mid-launch HALT sent keys"

echo "== W13: INDETERMINATE ledger -> alert, and NOTHING is launched or prompted"
reset
printf '%s\n' "$HEADER" "| R1 | 2026-07-14 | broken row with | six cells | open |" > "$LEDGER"
run_wd
[ "$(invoked new-session)" = "0" ] && ok "indeterminate: no launch" || bad "indeterminate launched"
[ -e "$WDIR/ALERT-intake-indeterminate" ] && ok "indeterminate: alert raised" || bad "indeterminate: silent"
reset
: > "$LEDGER"                                      # empty file: no header is not 'no work'
run_wd
[ "$(invoked new-session)" = "0" ] && [ -e "$WDIR/ALERT-intake-indeterminate" ] \
  && ok "headerless ledger treated as indeterminate" || bad "headerless ledger treated as idle"

echo "== W14: live attempts count as pending; stale state does not; malformed state alerts AND resumes"
reset
cat > "$R/.orchestrator/state/SPEC-099.json" <<'EOF'
{ "status": "running", "attempt_id": "SPEC-099-1" }
EOF
run_wd
[ "$(invoked new-session)" = "0" ] && ok "stale running-state without an active unit: no launch" || bad "stale state launched"
echo "codex-SPEC-099-1" > "$FAKE_ACTIVE_UNITS"
run_wd
[ "$(invoked new-session)" = "1" ] && ok "live attempt: session launched to supervise it" || bad "live attempt ignored"
reset
cat > "$R/.orchestrator/state/SPEC-098.json" <<'EOF'
{ "status": "running" }
EOF
run_wd
[ -e "$WDIR/ALERT-state-malformed" ] && ok "malformed running-state raised an alert" || bad "malformed state silent"
[ "$(invoked new-session)" = "1" ] && ok "malformed state fails closed to 'resume and look'" || bad "malformed state treated as idle"

echo "== W15: single flight — a held lock excludes; two rapid checks produce one session"
reset; open_row
mkdir -p "$WDIR"; chmod 700 "$WDIR"
(
  exec 9>>"$WDIR/lock"; flock 9
  run_wd
)
[ "$(invoked new-session)" = "0" ] && ok "check under a held lock is a no-op" || bad "lock did not exclude"
run_wd & run_wd & wait
[ "$(invoked new-session)" = "1" ] && ok "two rapid checks created exactly one session" || bad "concurrent checks created $(invoked new-session) sessions"

echo "== W16: installer — renders, refuses foreign units, backs up its own, refuses active mode"
reset
IH="$tmp/fakehome"; rm -rf "$IH"; mkdir -p "$IH/.config/systemd/user"
printf '%s\n' "someone else's unit" > "$IH/.config/systemd/user/other.timer"
inst() { PATH="$F:$PATH" HOME="$IH" ORCH_ROOT="$R" ORCH_WATCHDOG_DIR="$WDIR" bash "$R/scripts/install-watchdog" "$@" >> "$tmp/wd.log" 2>&1; }
inst install && ok "install succeeded" || bad "install failed: $(tail -3 "$tmp/wd.log")"
[ -e "$IH/.config/systemd/user/orchestrator-watchdog.timer" ] && ok "timer rendered" || bad "timer missing"
grep -q "ExecStart=$R/scripts/watchdog check" "$IH/.config/systemd/user/orchestrator-watchdog.service" && ok "service points at this checkout" || bad "service ExecStart wrong"
[ "$(stat -c %a "$WDIR/env")" = "600" ] && ok "env rendered mode 600" || bad "env mode wrong"
grep -q '^USAGE_RETRY_MODE=observe' "$WDIR/env" && ok "default mode is observe" || bad "default mode not observe"
inst install && ok "re-install is idempotent" || bad "re-install failed"
[ -e "$IH/.config/systemd/user/orchestrator-watchdog.timer.bak" ] && ok "re-install backed up the previous rendering" || bad "no backup on re-render"
sed -i 's/^USAGE_RETRY_MODE=observe/USAGE_RETRY_MODE=active/' "$WDIR/env"
inst install && bad "install accepted USAGE_RETRY_MODE=active" || ok "install refuses active retry mode (gate 9 is the owner's)"
ORCH_ALLOW_ACTIVE_RETRY=1 PATH="$F:$PATH" HOME="$IH" ORCH_ROOT="$R" ORCH_WATCHDOG_DIR="$WDIR" bash "$R/scripts/install-watchdog" install >> "$tmp/wd.log" 2>&1 \
  && ok "owner override installs active mode" || bad "owner override rejected"
sed -i 's/^USAGE_RETRY_MODE=active/USAGE_RETRY_MODE=observe/' "$WDIR/env"
printf '%s\n' "foreign same-named unit" > "$IH/.config/systemd/user/orchestrator-watchdog.timer"
inst install && bad "install overwrote a foreign same-named unit" || ok "install refuses a foreign same-named unit"
: > "$TS/invocations.log"
inst uninstall
[ -e "$IH/.config/systemd/user/orchestrator-watchdog.timer" ] && ok "uninstall left the foreign same-named unit" || bad "uninstall deleted a foreign unit"
grep -q 'disable --now.*orchestrator-watchdog.timer' "$TS/invocations.log" && bad "uninstall disabled a unit it does not own" || ok "uninstall did not disable the foreign unit"
[ ! -e "$IH/.config/systemd/user/orchestrator-watchdog.service" ] && ok "uninstall removed its own service" || bad "uninstall left its own service"
[ -e "$IH/.config/systemd/user/other.timer" ] && ok "unrelated unit untouched" || bad "unrelated unit deleted"

echo "== W17b: failed initial send-keys -> empty session torn down, fresh id next launch, no --resume of a ghost"
reset; open_row
export FAKE_TMUX_FAIL=send-keys
run_wd                                             # new-session ok, prompt delivery fails
unset FAKE_TMUX_FAIL
[ ! -e "$WDIR/launched" ] && [ ! -e "$WDIR/last-run" ] && ok "undelivered launch left no launched/run marks" || bad "ghost launch marked as launched/run"
run_wd                                             # incomplete launch detected
tmux_has() { [ -e "$TS/sessions/orch-auto" ]; }
tmux_has && bad "empty session survived" || ok "empty session torn down"
grep -q -- '--resume' <(keys) && bad "a never-started conversation was --resume'd" || ok "no --resume of the ghost id"
run_wd                                             # fresh launch
grep -q -- '--session-id 00000000-0000-4000-8000-000000000002' <(keys) && ok "relaunched fresh with a NEW id" || bad "relaunch did not mint a new id"
[ "$(cat "$WDIR/launched" 2>/dev/null)" = "00000000-0000-4000-8000-000000000002" ] && ok "launched marker matches the new id" || bad "launched marker wrong"

echo "== W17c: failed kill-session during teardown -> state retained, retried, never read as corrupt"
reset; open_row
export FAKE_TMUX_FAIL=send-keys
run_wd                                             # incomplete launch (session up, prompt undelivered)
export FAKE_TMUX_FAIL=kill-session
run_wd                                             # teardown attempt fails
[ -e "$TS/sessions/orch-auto" ] && ok "failed kill left the session (as simulated)" || bad "test setup broken: session vanished"
[ -e "$WDIR/session-id" ] && ok "failed teardown kept the recorded id" || bad "id dropped despite surviving session"
[ ! -e "$WDIR/ALERT-corrupt-session-id" ] && ok "failed teardown never read as corrupt state" || bad "failed teardown raised corrupt-session-id"
unset FAKE_TMUX_FAIL
run_wd                                             # teardown retried and succeeds
[ ! -e "$TS/sessions/orch-auto" ] && [ ! -e "$WDIR/session-id" ] && ok "teardown retried and completed" || bad "teardown retry failed"
run_wd                                             # fresh launch
grep -q -- '--session-id' <(keys) && ok "recovery completed with a fresh launch" || bad "no relaunch after retried teardown"

echo "== W12c (e): HALT landing AFTER session creation -> no prompt, then clean teardown and relaunch"
reset; open_row
export FAKE_TMUX_MAKE_HALT_ON=new-session FAKE_TMUX_HALT_PATH="$R/.orchestrator/HALT"
run_wd
unset FAKE_TMUX_MAKE_HALT_ON FAKE_TMUX_HALT_PATH
[ -z "$(keys)" ] && ok "post-new-session HALT: no prompt delivered" || bad "prompt delivered despite HALT"
[ ! -e "$WDIR/launched" ] && ok "post-new-session HALT: not marked launched" || bad "HALTed launch marked launched"
rm -f "$R/.orchestrator/HALT"
run_wd                                             # teardown of the incomplete session
[ ! -e "$TS/sessions/orch-auto" ] && ok "incomplete session removed after HALT cleared" || bad "incomplete session kept"
run_wd                                             # fresh launch
grep -q -- '--session-id' <(keys) && ok "fresh launch after recovery" || bad "no relaunch after recovery"

echo "== W17: hermetic — fakes answered every risky call; the fake claude was never truly executed"
reset; open_row
export FAKE_TMUX_FAIL=new-session
run_wd
[ ! -e "$WDIR/last-run" ] && ok "failed new-session did not count as a run" || bad "failed launch refreshed last-run"
unset FAKE_TMUX_FAIL
run_wd
[ "$(invoked new-session)" = "2" ] && [ -e "$WDIR/last-run" ] && ok "launch retried and succeeded next tick" || bad "no retry after failure"
[ ! -e "$TS/breach.log" ] && ok "claude was never executed beyond --version" || bad "HERMETIC BREACH: $(cat "$TS/breach.log")"

if [ "$fails" -eq 0 ]; then echo "PASS auto_resume_watchdog.sh"; else echo "FAIL auto_resume_watchdog.sh"; exit 1; fi
