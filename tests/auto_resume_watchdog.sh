#!/usr/bin/env bash
# Hermetic drill for the auto-resume watchdog (R39 brief, hermetic behavior gate). Everything runs
# under a scratch root with fake claude/tmux/systemctl/curl/uuidgen/loginctl/ps on PATH: no real
# claude, no real tmux server, no user units, no network, no repository runtime state — and no
# real process table, or the claude session RUNNING this drill would trip the standby guard. The fakes
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
    -d|-o|-p|-P) shift ;;
    -c|-x|-y|-F) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
# A '$N' target is a SESSION ID: resolve it to the session currently holding that id, exactly like
# real tmux — ids are never reused, so a stale id resolves to nothing and the command fails. This
# is what lets the drill prove actions bound to a verified id cannot reach a replacement.
case "$name" in
  '$'*|'%'*) f=1; [ "${name#'%'}" = "$name" ] || f=4   # '$N' matches field 1 (session id), '%N' field 4 (pane id)
        resolved=""
        for p in "$S/sessions/"*.pane; do
          [ -e "$p" ] || continue
          if [ "$(head -1 "$p" | cut -d: -f$f)" = "$name" ]; then resolved="${p%.pane}"; resolved="${resolved##*/}"; break; fi
        done
        [ -n "$resolved" ] || exit 1
        name=$resolved ;;
esac
case "$cmd" in
  has-session)    [ -e "$S/sessions/$name" ] ;;
  new-session)    touch "$S/sessions/$name"; echo bash > "$S/sessions/$name.cmd"
                  printf '$0:100:500:%%5\n' > "$S/sessions/$name.pane"
                  printf '$0:100:500:%%5\n'                  # -P: the created session's own identity
                  # replacement hook: the session is swapped for a foreign one the instant it exists
                  if [ -n "${FAKE_TMUX_SWAP_AFTER_NEW:-}" ]; then printf '$7:900:800:%%9\n' > "$S/sessions/$name.pane"; fi ;;
  send-keys)      printf '%s\n' "${args[*]}" >> "$S/sessions/$name.keys"
                  echo claude > "$S/sessions/$name.cmd" ;;
  display-message) cat "$S/sessions/$name.cmd" 2>/dev/null || echo bash ;;
  list-panes)     m=$(cat "$S/lp-count" 2>/dev/null || echo 0); m=$((m+1)); echo "$m" > "$S/lp-count"
                  cat "$S/sessions/$name.pane" 2>/dev/null || exit 1
                  # replacement hooks, firing immediately AFTER this read — the window between
                  # verification and the action: SWAP_LP replaces the whole session; SWAP_PANE_LP
                  # keeps the session id but replaces the pane inside it
                  if [ -n "${FAKE_TMUX_SWAP_LP_ON:-}" ] && [ "$FAKE_TMUX_SWAP_LP_ON" -le "$m" ]; then printf '$7:900:800:%%9\n' > "$S/sessions/$name.pane"; fi
                  if [ -n "${FAKE_TMUX_SWAP_PANE_LP_ON:-}" ] && [ "$FAKE_TMUX_SWAP_PANE_LP_ON" -le "$m" ]; then printf '$0:100:501:%%9\n' > "$S/sessions/$name.pane"; fi ;;
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

cat > "$F/ps" <<'FAKE'
#!/usr/bin/env bash
# Answers only `ps -eo pid=,ppid=,comm=`, printing the FAKE_PS_TABLE file ("pid ppid comm" per
# line). Unset table = empty process table (the real one would show the claude running this very
# drill). FAKE_PS_FAIL simulates an unreadable table. Every invocation is counted so a scenario
# can target the SECOND detection of one tick — the per-action barrier — deterministically:
#   FAKE_PS_ADD_ROW      extra row printed once the call count exceeds FAKE_PS_ADD_AFTER
#   FAKE_PS_MAKE_HALT    HALT path touched from call FAKE_PS_MAKE_HALT_ON (default 1) onward
n=$(cat "$FAKE_PS_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FAKE_PS_COUNT"
echo "ps $*" >> "$FAKE_TMUX_STATE/invocations.log"   # shared log: adjacency assertions read the ORDER
[ -n "${FAKE_PS_MAKE_HALT:-}" ] && [ "${FAKE_PS_MAKE_HALT_ON:-1}" -le "$n" ] && touch "$FAKE_PS_MAKE_HALT"
# identity-swap hook: the supervised session is replaced DURING this presence read — proves the
# action authorization is re-read after the scan, not before it
[ -n "${FAKE_PS_SWAP_PANE:-}" ] && [ "${FAKE_PS_SWAP_ON:-1}" -le "$n" ] && printf '$7:900:800:%%9\n' > "$FAKE_TMUX_STATE/sessions/orch-auto.pane"
[ -n "${FAKE_PS_FAIL:-}" ] && exit 3
[ "$*" = "-eo pid=,ppid=,comm=" ] || exit 1
[ -n "${FAKE_PS_TABLE:-}" ] && cat "$FAKE_PS_TABLE" 2>/dev/null
[ -n "${FAKE_PS_ADD_ROW:-}" ] && [ "$n" -gt "${FAKE_PS_ADD_AFTER:-0}" ] && printf '%s\n' "$FAKE_PS_ADD_ROW"
exit 0
FAKE
chmod +x "$F"/*

export FAKE_TMUX_STATE="$TS" FAKE_ACTIVE_UNITS="$tmp/active-units" FAKE_CURL_LOG="$tmp/curl.log" FAKE_UUID_COUNT="$tmp/uuid-count" FAKE_PS_COUNT="$tmp/ps-count"

WDIR="$R/.orchestrator/watchdog"
run_wd() { # run one watchdog invocation in the sandbox
  PATH="$F:$PATH" ORCH_ROOT="$R" ORCH_WATCHDOG_DIR="$WDIR" ORCH_TMUX_SESSION=orch-auto \
    bash "$R/scripts/watchdog" "${@:-check}" >> "$tmp/wd.log" 2>&1
}
reset() { # fresh state between scenarios
  rm -rf "$WDIR" "$TS" "$R/.orchestrator/HALT" "$R/.orchestrator/state" "$R/scripts/lib/usage-framings"
  mkdir -p "$TS/sessions" "$R/.orchestrator/state" "$R/scripts/lib/usage-framings"
  rm -f "$FAKE_CURL_LOG" "$FAKE_ACTIVE_UNITS" "$FAKE_UUID_COUNT" "$FAKE_PS_COUNT" "$LEDGER.lock"
  printf '%s\n' "$HEADER" > "$LEDGER"
  unset FAKE_CURL_EXIT FAKE_TMUX_FAIL FAKE_CLAUDE_VERSION FAKE_PS_TABLE FAKE_PS_FAIL \
        FAKE_PS_MAKE_HALT FAKE_PS_MAKE_HALT_ON FAKE_PS_ADD_ROW FAKE_PS_ADD_AFTER \
        FAKE_PS_SWAP_PANE FAKE_PS_SWAP_ON FAKE_TMUX_SWAP_AFTER_NEW FAKE_TMUX_SWAP_LP_ON FAKE_TMUX_SWAP_PANE_LP_ON 2>/dev/null || true
}
open_row() { (cd "$R" && scripts/intake -g "${1:-drill goal}" -d "done when the drill criterion holds" >/dev/null); }
keys() { cat "$TS/sessions/orch-auto.keys" 2>/dev/null || true; }
invoked() { # count of a given tmux subcommand; a missing log means zero calls, not a broken count
  [ -e "$TS/invocations.log" ] || { echo 0; return; }
  grep -c "^tmux $1" "$TS/invocations.log" || true
}
dead_pane() { echo bash > "$TS/sessions/orch-auto.cmd"; }
bind_session() { # record the ownership binding a real launch would have written ($0:100:500:%5 is
  # the fake tmux's constant identity) — hand-built sessions need it now that every action verifies it
  mkdir -p "$WDIR"
  printf '$0:100:500:%%5\n' > "$TS/sessions/orch-auto.pane"
  printf '$0:100:500:%%5\n' > "$WDIR/pane"
}
adjacent() { # $1 action regex: the LAST such action must be immediately preceded by the identity
  # verification (list-panes) with the presence read (ps) right before that — proof that the
  # authorization is the final external read, and nothing else runs between the barrier and the action
  awk -v act="$1" '{l[NR]=$0} END{for(i=NR;i>2;i--) if (l[i] ~ act) { exit ((l[i-1] ~ /^tmux list-panes/ && l[i-2] ~ /^ps /) ? 0 : 1) }; exit 1}' "$TS/invocations.log"
}
adjacent_after_pipe() { # launch variant: pipe-pane (itself bound to the verified id) sits between
  # the verification and the send — still nothing unaudited in the window
  awk -v act="$1" '{l[NR]=$0} END{for(i=NR;i>3;i--) if (l[i] ~ act) { exit ((l[i-1] ~ /^tmux pipe-pane/ && l[i-2] ~ /^tmux list-panes/ && l[i-3] ~ /^ps /) ? 0 : 1) }; exit 1}' "$TS/invocations.log"
}
alert_env() { # configure a complete owner alert channel
  mkdir -p "$WDIR"
  printf 'ALERT_URL=https://alerts.invalid/topic\nALERT_TOKEN=drill-token\n' >> "$WDIR/env"
  chmod 600 "$WDIR/env"
}

echo "== W0: tracked resume prompt carries every binding instruction, in the required order"
P="scripts/lib/watchdog-resume-prompt.txt"
for phrase in "HALT" "dispatch reconcile" "CLAUDE.md" "scripts/intake" "NEVER touch main" "NEVER create approval files" "heartbeat" "observation rows" "exit claude entirely" "write a dated handoff" "compacted"; do
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

echo "== W2: no pending work -> no launch; a dead idle pane is ROTATED (torn down, id retired)"
reset
run_wd
[ "$(invoked new-session)" = "0" ] && [ -z "$(keys)" ] && ok "idle: no session, no keys" || bad "idle run acted"
mkdir -p "$TS/sessions"; touch "$TS/sessions/orch-auto"; dead_pane; bind_session
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/session-id"; printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/launched"
run_wd
[ -z "$(keys)" ] && ok "rotation typed nothing" || bad "rotation sent input"
[ ! -e "$TS/sessions/orch-auto" ] && ok "dead idle session torn down" || bad "dead idle session survived rotation"
[ ! -e "$WDIR/session-id" ] && [ ! -e "$WDIR/launched" ] && ok "conversation id retired" || bad "id survived rotation"
open_row                                            # work appears after rotation
run_wd
grep -q -- '--session-id 00000000-0000-4000-8000-000000000001' <(keys) && ok "next pending wake started FRESH (new id, not --resume)" || bad "post-rotation wake did not start fresh"
grep -q -- '--resume' <(keys) && bad "post-rotation wake resumed a retired conversation" || ok "retired conversation never resumed"

echo "== W2b: rotation respects a LIVE idle session and survives a failed kill"
reset
mkdir -p "$TS/sessions"; touch "$TS/sessions/orch-auto"; echo claude > "$TS/sessions/orch-auto.cmd"; bind_session
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/session-id"
run_wd
[ -e "$TS/sessions/orch-auto" ] && ok "live idle session left alone (rotation is session-initiated)" || bad "rotation killed a LIVE session"
dead_pane
export FAKE_TMUX_FAIL=kill-session
run_wd
unset FAKE_TMUX_FAIL
[ -e "$WDIR/session-id" ] && ok "failed rotation kill kept the id (retry next tick)" || bad "id dropped despite surviving session"
run_wd
[ ! -e "$TS/sessions/orch-auto" ] && [ ! -e "$WDIR/session-id" ] && ok "rotation retried and completed" || bad "rotation retry failed"

echo "== W2c: an INDETERMINATE pane probe fails closed — no rotation, no respawn, no typing"
reset
mkdir -p "$TS/sessions"; touch "$TS/sessions/orch-auto"; echo claude > "$TS/sessions/orch-auto.cmd"
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/session-id" 2>/dev/null || { mkdir -p "$WDIR"; printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/session-id"; }
export FAKE_TMUX_FAIL=display-message
run_wd                                             # IDLE + probe failure
[ -e "$TS/sessions/orch-auto" ] && [ -e "$WDIR/session-id" ] && ok "idle + failed probe: nothing killed, nothing retired" || bad "failed probe rotated a possibly-live session"
open_row
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/launched"
run_wd                                             # PENDING + probe failure
unset FAKE_TMUX_FAIL
[ -z "$(keys)" ] && ok "pending + failed probe: no respawn, no keys typed into an unknown pane" || bad "failed probe caused session input"

echo "== W2d: idle rotation refuses corrupt ownership instead of erasing it"
reset
mkdir -p "$TS/sessions"; touch "$TS/sessions/orch-auto"; dead_pane
mkdir -p "$WDIR"; echo "not-a-uuid" > "$WDIR/session-id"
run_wd
[ -e "$TS/sessions/orch-auto" ] && [ -e "$WDIR/session-id" ] && ok "corrupt id under idle: session and state untouched" || bad "idle rotation erased corrupt state"
[ -e "$WDIR/ALERT-corrupt-session-id" ] && ok "corrupt id under idle: visible refusal alert" || bad "corrupt id under idle failed silently"

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

ps_table() { printf '%s\n' "$@" > "$tmp/ps-table"; export FAKE_PS_TABLE="$tmp/ps-table"; }

echo "== W18: user-presence standby — a foreign claude parks the watchdog, resumes when it exits"
reset; open_row
ps_table "4242 1 claude"                           # a claude the watchdog does not supervise
run_wd
[ "$(invoked new-session)" = "0" ] && [ -z "$(keys)" ] && ok "standby: no launch while a user claude runs" || bad "standby launched anyway"
[ -e "$WDIR/standby" ] && ok "standby marker written" || bad "no standby marker"
n_notes=$(grep -c 'supervision paused' "$tmp/wd.log")
run_wd
[ "$(grep -c 'supervision paused' "$tmp/wd.log")" = "$n_notes" ] && ok "one 'paused' note per flip, not per tick" || bad "standby note repeated every tick"
[ ! -e "$WDIR/last-run" ] && ok "standby ticks never counted as runs" || bad "standby refreshed last-run"
unset FAKE_PS_TABLE
n_clear=$(grep -c 'standby cleared' "$tmp/wd.log" || true)
run_wd
[ ! -e "$WDIR/standby" ] && ok "standby cleared once the user claude exited" || bad "standby stuck after the user claude exited"
[ "$(invoked new-session)" = "1" ] && ok "supervision resumed with a launch on the next tick" || bad "no launch after standby cleared"
run_wd
[ "$(grep -c 'standby cleared' "$tmp/wd.log")" = "$((n_clear + 1))" ] && ok "one 'cleared' note per flip, not per tick" || bad "cleared note repeated or missing"

echo "== W18b: own supervised claude (any ancestry depth) never standby; a foreign one beside it does"
reset; open_row
run_wd                                             # launch: session up, pane binding '$0:100:500' recorded
ps_table "500 402 bash" "510 500 claude"           # claude 510 is a child of the pane shell
run_wd
[ ! -e "$WDIR/standby" ] && ok "own supervised claude: no standby" || bad "watchdog stood down for its own claude"
ps_table "500 402 bash" "520 500 node" "530 520 claude"
run_wd
[ ! -e "$WDIR/standby" ] && ok "multi-hop ancestry to the pane: still ours" || bad "multi-hop own claude read as foreign"
ps_table "500 402 bash" "510 500 claude" "4242 1 claude"
run_wd
[ -e "$WDIR/standby" ] && ok "own + foreign mixed: stood down" || bad "a foreign claude hid behind the supervised one"
unset FAKE_PS_TABLE; run_wd                        # clear between cases
ps_table "500 402 bash" "530 520 claude"           # ancestor 520 missing from the snapshot
run_wd
[ -e "$WDIR/standby" ] && ok "broken ancestry mid-walk: foreign, stood down" || bad "unattributable claude read as ours"
ps_table "4242 1 claude"
dead_pane                                          # supervised claude exits while a foreign one runs
n_before=$(keys | wc -l)
run_wd
[ "$(keys | wc -l)" = "$n_before" ] && [ -e "$WDIR/standby" ] && ok "dead pane + foreign claude: respawn deferred to standby" || bad "respawn ran during standby"
unset FAKE_PS_TABLE
run_wd
grep -q -- '--resume' <(keys) && ok "respawn happened once the user claude exited" || bad "no respawn after standby cleared"

echo "== W18c: a pane is trusted only while provably ours NOW — every distrust form stands down"
reset; open_row
run_wd                                             # launch records binding '$0:100:500'
ps_table "500 402 bash" "510 500 claude"
run_wd
[ ! -e "$WDIR/standby" ] && ok "matching binding: own claude trusted (baseline)" || bad "trusted baseline broken"
rm -f "$TS/sessions/orch-auto.pane"
run_wd
[ -e "$WDIR/standby" ] && ok "unreadable pane identity: stood down" || bad "unreadable pane identity trusted"
printf '$0:100:500:%%5\n' > "$TS/sessions/orch-auto.pane"; run_wd   # restore, clears
printf '$5:200:500:%%5\n' > "$TS/sessions/orch-auto.pane"           # same name, same pane pid, DIFFERENT session
run_wd
[ -e "$WDIR/standby" ] && ok "recreated same-name session: stale-but-valid records never trusted" || bad "stale records laundered a foreign session"
printf '$0:100:500:%%5\n' > "$TS/sessions/orch-auto.pane"; run_wd   # restore, clears
printf '$0:100:500:%%5\n$0:100:501:%%6\n' > "$TS/sessions/orch-auto.pane"
run_wd
[ -e "$WDIR/standby" ] && ok "multi-pane session: untrusted, stood down" || bad "multi-pane session trusted"
printf '$0:100:500:%%5\n' > "$TS/sessions/orch-auto.pane"; run_wd   # restore, clears
ps_table "500 1 claude" "510 500 claude"                        # pane pid alive but NOT a shell
run_wd
[ -e "$WDIR/standby" ] && ok "pane pid not a shell in the snapshot: untrusted" || bad "non-shell pane pid vouched for a claude"
ps_table "500 402 bash" "510 500 claude"; run_wd                # restore, clears
rm -f "$WDIR/launched"
run_wd
[ -e "$WDIR/standby" ] && ok "ownership record broken: untrusted, stood down" || bad "pane trusted without the launched marker"
unset FAKE_PS_TABLE

echo "== W18d: HALT at entry wins over standby — strict no-op, not even a standby marker"
reset; open_row
touch "$R/.orchestrator/HALT"
ps_table "4242 1 claude"
run_wd
unset FAKE_PS_TABLE
[ ! -d "$WDIR" ] && ok "HALT before standby: no state written at all" || bad "HALT run still wrote state"
rm -f "$R/.orchestrator/HALT"

echo "== W18e: standby suppresses the idle alert but never delivery retries"
reset; open_row
run_wd                                             # launch records last-run
alert_env
echo "$(( $(date +%s) - 30000 ))" > "$WDIR/last-run"
printf 'ts=1\ntype=drill\nmsg=stranded incident from before standby\n' > "$WDIR/ALERT-drill"
last_before=$(cat "$WDIR/last-run")
ps_table "4242 1 claude"
run_wd
unset FAKE_PS_TABLE
[ ! -e "$WDIR/ALERT-idle" ] && ok "standby: idle alert suppressed" || bad "idle alert fired during standby"
grep -q '^sent=' "$WDIR/ALERT-drill" && ok "standby: stranded incident still delivered by the sweep" || bad "standby blocked the delivery sweep"
[ "$(cat "$WDIR/last-run")" = "$last_before" ] && ok "standby left last-run untouched" || bad "standby changed last-run"

echo "== W18f: HALT landing DURING detection (via the ps hook) still wins — no marker, no note"
reset; open_row
ps_table "4242 1 claude"
export FAKE_PS_MAKE_HALT="$R/.orchestrator/HALT"
run_wd
unset FAKE_PS_MAKE_HALT FAKE_PS_TABLE
[ ! -e "$WDIR/standby" ] && ok "mid-detection HALT: no standby marker written" || bad "marker written despite HALT"
[ "$(invoked new-session)" = "0" ] && ok "mid-detection HALT: nothing launched" || bad "launched despite HALT"
rm -f "$R/.orchestrator/HALT"

echo "== W18g: unreadable process table fails toward standby, VISIBLY"
reset; open_row
export FAKE_PS_FAIL=1
run_wd
[ "$(invoked new-session)" = "0" ] && [ -e "$WDIR/standby" ] && ok "ps failure: stood down, no launch" || bad "ps failure did not stand down"
[ -e "$WDIR/ALERT-standby-indeterminate" ] && ok "ps failure raised its own incident" || bad "ps failure is silent"
unset FAKE_PS_FAIL
run_wd
[ ! -e "$WDIR/standby" ] && [ "$(invoked new-session)" = "1" ] && ok "recovered ps: standby cleared, launch resumed" || bad "no recovery after ps healed"

echo "== W18h: a claude appearing in the detection-to-send window is caught at the LAUNCH gate"
reset; open_row
rm -f "$FAKE_PS_COUNT"
export FAKE_PS_ADD_ROW="7777 1 claude" FAKE_PS_ADD_AFTER=1   # entry detection clean; every later one sees it
run_wd
[ "$(invoked new-session)" = "1" ] && [ -z "$(keys)" ] && ok "launch gate: session created, prompt WITHHELD" || bad "prompt sent through the race window"
[ ! -e "$WDIR/launched" ] && ok "withheld prompt never marked launched" || bad "launched marker written without a prompt"
run_wd
[ -e "$WDIR/standby" ] && ok "next tick's entry detection parked it" || bad "race-window claude never parked"
unset FAKE_PS_ADD_ROW FAKE_PS_ADD_AFTER
run_wd                                              # standby clears; incomplete launch torn down
run_wd                                              # fresh relaunch
grep -q -- '--session-id' <(keys) && ok "recovered with a fresh launch once the user left" || bad "no recovery after the deferred launch"

echo "== W18i: an armed ACTIVE-mode retry is deferred, not consumed, during standby"
reset; open_row
run_wd                                              # launch
printf 'USAGE_RETRY_MODE=active\n' > "$WDIR/env"; chmod 600 "$WDIR/env"
gen=$(cat "$WDIR/generation")
echo "$(( $(date +%s) - 60 )) $gen drill.sed" > "$WDIR/usage-wait"
ps_table "4242 1 claude"
n_before=$(keys | wc -l)
run_wd
[ "$(keys | wc -l)" = "$n_before" ] && ok "standby: no retry input sent" || bad "retry sent during standby"
[ -e "$WDIR/usage-wait" ] && ok "standby: the armed wait stays armed" || bad "standby consumed the wait"
unset FAKE_PS_TABLE
run_wd
[ "$(keys | wc -l)" = "$((n_before + 1))" ] && keys | tail -1 | grep -q "usage window has reset" \
  && ok "deferred retry fired once the user left" || bad "deferred retry lost"

echo "== W18j: idle rotation is deferred during standby, never a teardown over a user's head"
reset                                               # no open row: IDLE state
mkdir -p "$TS/sessions"; touch "$TS/sessions/orch-auto"; dead_pane; bind_session
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/session-id"
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/launched"
ps_table "4242 1 claude"
run_wd
[ -e "$TS/sessions/orch-auto" ] && [ -e "$WDIR/session-id" ] && ok "standby: idle rotation deferred" || bad "rotation ran during standby"
unset FAKE_PS_TABLE
run_wd
[ ! -e "$TS/sessions/orch-auto" ] && [ ! -e "$WDIR/session-id" ] && ok "rotation completed once the user left" || bad "rotation never resumed"

echo "== W18k: a claude appearing between entry detection and a RESPAWN is caught at the send gate"
reset; open_row
run_wd                                              # launch (prompt delivered)
dead_pane
rm -f "$FAKE_PS_COUNT"
export FAKE_PS_ADD_ROW="7777 1 claude" FAKE_PS_ADD_AFTER=1
n_before=$(keys | wc -l)
run_wd
[ "$(keys | wc -l)" = "$n_before" ] && ok "respawn gate: no --resume typed through the race window" || bad "respawn ran through the race window"
unset FAKE_PS_ADD_ROW FAKE_PS_ADD_AFTER
run_wd
grep -q -- '--resume' <(keys) && ok "respawn completed once the user left" || bad "deferred respawn lost"

echo "== W18l: a claude appearing before an armed ACTIVE retry is caught BEFORE the wait is consumed"
reset; open_row
run_wd
printf 'USAGE_RETRY_MODE=active\n' > "$WDIR/env"; chmod 600 "$WDIR/env"
gen=$(cat "$WDIR/generation")
echo "$(( $(date +%s) - 60 )) $gen drill.sed" > "$WDIR/usage-wait"
rm -f "$FAKE_PS_COUNT"
export FAKE_PS_ADD_ROW="7777 1 claude" FAKE_PS_ADD_AFTER=1
n_before=$(keys | wc -l)
run_wd
[ "$(keys | wc -l)" = "$n_before" ] && [ -e "$WDIR/usage-wait" ] && ok "retry gate: nothing sent, wait STILL armed" || bad "retry raced through or the wait was consumed"
unset FAKE_PS_ADD_ROW FAKE_PS_ADD_AFTER
run_wd
[ "$(keys | wc -l)" = "$((n_before + 1))" ] && ok "deferred retry fired once the user left" || bad "deferred retry lost"

echo "== W18m: a claude appearing before an idle ROTATION is caught at the kill gate"
reset                                               # no open row: IDLE
mkdir -p "$TS/sessions"; touch "$TS/sessions/orch-auto"; dead_pane; bind_session
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/session-id"
rm -f "$FAKE_PS_COUNT"
export FAKE_PS_ADD_ROW="7777 1 claude" FAKE_PS_ADD_AFTER=1
run_wd
[ -e "$TS/sessions/orch-auto" ] && [ -e "$WDIR/session-id" ] && ok "rotation gate: teardown deferred through the race window" || bad "rotation raced through"
unset FAKE_PS_ADD_ROW FAKE_PS_ADD_AFTER
run_wd
[ ! -e "$TS/sessions/orch-auto" ] && ok "deferred rotation completed once the user left" || bad "rotation never resumed"

echo "== W18n: a claude appearing before an IDLE ALERT is caught — a user working IS activity"
reset; open_row
run_wd
echo "$(( $(date +%s) - 30000 ))" > "$WDIR/last-run"
rm -f "$FAKE_PS_COUNT"
export FAKE_PS_ADD_ROW="7777 1 claude" FAKE_PS_ADD_AFTER=1
run_wd
[ ! -e "$WDIR/ALERT-idle" ] && ok "idle-alert gate: no alert over a user's head" || bad "idle alert raced through"
unset FAKE_PS_ADD_ROW FAKE_PS_ADD_AFTER
run_wd
[ -e "$WDIR/ALERT-idle" ] && ok "idle alert fired once the user left" || bad "idle alert lost"

echo "== W18o: HALT landing DURING a mid-tick barrier detection still wins — no input sent"
reset; open_row
run_wd
dead_pane
rm -f "$FAKE_PS_COUNT"
export FAKE_PS_MAKE_HALT="$R/.orchestrator/HALT" FAKE_PS_MAKE_HALT_ON=2
n_before=$(keys | wc -l)
run_wd
unset FAKE_PS_MAKE_HALT FAKE_PS_MAKE_HALT_ON
[ "$(keys | wc -l)" = "$n_before" ] && ok "HALT during the respawn barrier: no --resume sent" || bad "input sent despite mid-barrier HALT"
rm -f "$R/.orchestrator/HALT"

echo "== W19: a foreign same-name session is never typed into — respawn refuses VISIBLY"
# The shape round 3 found: NO claude runs anywhere (standby never triggers), the session name
# exists, but it is not the session this watchdog created.
reset; open_row
run_wd                                              # launch; binding '$0:100:500' recorded
dead_pane
printf '$7:900:800:%%9\n' > "$TS/sessions/orch-auto.pane"   # owner recreated the session: new identity
n_before=$(keys | wc -l)
run_wd                                              # PENDING + dead pane -> respawn path
[ "$(keys | wc -l)" = "$n_before" ] && ok "respawn refused: nothing typed into the foreign session" || bad "respawn typed into a foreign session"
[ -e "$TS/sessions/orch-auto" ] && ok "foreign session left alive" || bad "foreign session killed"
[ -e "$WDIR/ALERT-foreign-session" ] && ok "refusal is visible (foreign-session alert)" || bad "refusal silent"

echo "== W19b: incomplete-launch teardown refuses a foreign session"
reset; open_row
export FAKE_TMUX_FAIL=send-keys
run_wd                                              # incomplete launch: binding recorded, no launched marker
unset FAKE_TMUX_FAIL
printf '$7:900:800:%%9\n' > "$TS/sessions/orch-auto.pane"
run_wd                                              # teardown path
[ -e "$TS/sessions/orch-auto" ] && ok "teardown refused: foreign session survives" || bad "teardown killed a foreign session"
[ -e "$WDIR/session-id" ] && ok "our state kept (nothing laundered)" || bad "state erased on a refusal"
[ -e "$WDIR/ALERT-foreign-session" ] && ok "teardown refusal visible" || bad "teardown refusal silent"

echo "== W19c: idle rotation refuses a foreign session"
reset                                               # no open row: IDLE
mkdir -p "$TS/sessions"; touch "$TS/sessions/orch-auto"; dead_pane; bind_session
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/session-id"
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/launched"
printf '$7:900:800:%%9\n' > "$TS/sessions/orch-auto.pane"
run_wd
[ -e "$TS/sessions/orch-auto" ] && [ -e "$WDIR/session-id" ] && ok "rotation refused: session and state kept" || bad "rotation acted on a foreign session"
[ -e "$WDIR/ALERT-foreign-session" ] && ok "rotation refusal visible" || bad "rotation refusal silent"

echo "== W19d: an armed ACTIVE retry refuses a foreign session, and the wait stays armed"
reset; open_row
run_wd
printf 'USAGE_RETRY_MODE=active\n' > "$WDIR/env"; chmod 600 "$WDIR/env"
gen=$(cat "$WDIR/generation")
echo "$(( $(date +%s) - 60 )) $gen drill.sed" > "$WDIR/usage-wait"
printf '$7:900:800:%%9\n' > "$TS/sessions/orch-auto.pane"
n_before=$(keys | wc -l)
run_wd
[ "$(keys | wc -l)" = "$n_before" ] && ok "retry refused: nothing typed" || bad "retry typed into a foreign session"
[ -e "$WDIR/usage-wait" ] && ok "the wait stays armed" || bad "wait consumed on a refusal"
[ -e "$WDIR/ALERT-foreign-session" ] && ok "retry refusal visible" || bad "retry refusal silent"

echo "== W19e: a missing binding record refuses the action — nothing ever acts on the bare name"
reset; open_row
run_wd
dead_pane
rm -f "$WDIR/pane"
n_before=$(keys | wc -l)
run_wd
[ "$(keys | wc -l)" = "$n_before" ] && [ -e "$TS/sessions/orch-auto" ] && ok "no binding record: respawn refused, session untouched" || bad "action ran without a binding record"
[ -e "$WDIR/ALERT-foreign-session" ] && ok "missing-record refusal visible" || bad "missing-record refusal silent"

echo "== W19f: a send failure keeps the retry armed instead of silently spending it"
reset; open_row
run_wd
printf 'USAGE_RETRY_MODE=active\n' > "$WDIR/env"; chmod 600 "$WDIR/env"
gen=$(cat "$WDIR/generation")
echo "$(( $(date +%s) - 60 )) $gen drill.sed" > "$WDIR/usage-wait"
export FAKE_TMUX_FAIL=send-keys
run_wd
unset FAKE_TMUX_FAIL
[ -e "$WDIR/usage-wait" ] && ok "failed send: wait stays armed for the next tick" || bad "failed send consumed the wait"
run_wd
keys | tail -1 | grep -q "usage window has reset" && [ ! -e "$WDIR/usage-wait" ] \
  && ok "retry delivered next tick and the wait was consumed" || bad "armed wait never delivered"

echo "== W20: gate adjacency — presence read, then identity verification, then the action, nothing between"
reset; open_row
run_wd                                              # (a) initial send
adjacent_after_pipe 'tmux send-keys' && ok "launch: gates, then only id-bound actions until the send" || bad "launch: something unaudited runs between the gates and the send"
dead_pane
run_wd                                              # (b) respawn send
adjacent 'tmux send-keys' && ok "respawn: identity is the final read before the send" || bad "respawn: gates not adjacent to the send"
printf 'USAGE_RETRY_MODE=active\n' > "$WDIR/env"; chmod 600 "$WDIR/env"
gen=$(cat "$WDIR/generation")
echo "$(( $(date +%s) - 60 )) $gen drill.sed" > "$WDIR/usage-wait"
run_wd                                              # (c) retry send
adjacent 'tmux send-keys' && ok "retry: identity is the final read before the send" || bad "retry: gates not adjacent to the send"
reset
mkdir -p "$TS/sessions"; touch "$TS/sessions/orch-auto"; dead_pane; bind_session
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/session-id"
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/launched"
run_wd                                              # idle rotation kill
adjacent 'tmux kill-session' && ok "rotation: identity is the final read before the kill" || bad "rotation: gates not adjacent to the kill"

echo "== W22: identity replaced DURING the presence scan is caught — authorization is re-read after it"
reset; open_row
run_wd                                              # launch
dead_pane
rm -f "$FAKE_PS_COUNT"
export FAKE_PS_SWAP_PANE=1 FAKE_PS_SWAP_ON=2       # entry read clean; the respawn barrier read swaps identity
n_before=$(keys | wc -l)
run_wd
unset FAKE_PS_SWAP_PANE FAKE_PS_SWAP_ON
[ "$(keys | wc -l)" = "$n_before" ] && ok "respawn: swap during the barrier scan refused" || bad "acted on a session replaced during the presence scan"
[ -e "$WDIR/ALERT-foreign-session" ] && ok "stale-authorization refusal visible" || bad "stale-authorization refusal silent"

echo "== W22b: a same-name replacement right after creation is never bound as ours"
reset; open_row
export FAKE_TMUX_SWAP_AFTER_NEW=1                   # the session is replaced the instant it exists
run_wd
unset FAKE_TMUX_SWAP_AFTER_NEW
[ -z "$(keys)" ] && ok "initial prompt withheld from the replacement" || bad "typed into the replacement session"
[ ! -e "$WDIR/launched" ] && ok "replacement never marked launched" || bad "launched marker written for a replacement"
[ -e "$WDIR/ALERT-foreign-session" ] && ok "replacement refusal visible" || bad "replacement refusal silent"
[ "$(cat "$WDIR/pane")" = '$0:100:500:%5' ] && ok "binding records what creation printed, never a name lookup" || bad "binding captured the replacement's identity"
[ "$(invoked pipe-pane)" = "0" ] && ok "no transcript pipe ever attached to the replacement" || bad "pipe-pane ran against the replacement session"

echo "== W22c: a refused respawn advances neither the storm counter nor the generation"
reset; open_row
run_wd                                              # launch
gen_before=$(cat "$WDIR/generation")
dead_pane
printf '$7:900:800:%%9\n' > "$TS/sessions/orch-auto.pane"
run_wd                                              # foreign identity: respawn refused
[ "$(cat "$WDIR/generation")" = "$gen_before" ] && ok "generation unchanged on refusal" || bad "refusal bumped the generation"
[ "$(cat "$WDIR/respawns" 2>/dev/null || echo 0)" = "0" ] && ok "storm counter unchanged on refusal" || bad "refusal counted as a respawn"
printf '$0:100:500:%%5\n' > "$TS/sessions/orch-auto.pane"
run_wd                                              # genuine respawn
[ "$(cat "$WDIR/respawns")" = "1" ] && ok "a real respawn counts toward the storm alert" || bad "real respawn not counted"
[ "$(cat "$WDIR/generation")" != "$gen_before" ] && ok "a real respawn bumps the generation" || bad "generation not bumped by a real respawn"

echo "== W23: identity replaced right AFTER verification — the id-bound action fails instead of landing"
reset; open_row
run_wd                                              # launch
dead_pane
rm -f "$TS/lp-count"
export FAKE_TMUX_SWAP_LP_ON=3                       # entry lp, barrier lp, then the VERIFY read swaps after printing
n_before=$(keys | wc -l)
run_wd                                              # respawn: verify passes on the old triple, send targets the stale id
unset FAKE_TMUX_SWAP_LP_ON
[ "$(keys | wc -l)" = "$n_before" ] && ok "respawn: the send could not reach the replacement (stale id)" || bad "send landed on a session replaced after verification"
[ -e "$TS/sessions/orch-auto" ] && ok "replacement session untouched" || bad "replacement session killed or modified"
[ -e "$WDIR/session-id" ] && ok "state kept: the failed send retries next tick" || bad "state erased on a failed id-bound send"

echo "== W23c: a NEW PANE replacing ours inside the same session cannot receive input"
reset; open_row
run_wd                                              # launch
dead_pane
rm -f "$TS/lp-count"
export FAKE_TMUX_SWAP_PANE_LP_ON=3                  # verify read passes, then the pane is replaced within the session
n_before=$(keys | wc -l)
run_wd                                              # respawn: send targets the verified PANE id, now gone
unset FAKE_TMUX_SWAP_PANE_LP_ON
[ "$(keys | wc -l)" = "$n_before" ] && ok "respawn: send bound to the pane id could not reach the new pane" || bad "input landed in a replacement pane of the same session"
[ -e "$WDIR/session-id" ] && ok "state kept: the failed send retries next tick" || bad "state erased on the failed pane-bound send"

echo "== W23b: rotation kill after a post-verification replacement fails and keeps state"
reset                                               # no open row: IDLE
mkdir -p "$TS/sessions"; touch "$TS/sessions/orch-auto"; dead_pane; bind_session
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/session-id"
printf '00000000-0000-4000-8000-000000000099\n' > "$WDIR/launched"
rm -f "$TS/lp-count"
export FAKE_TMUX_SWAP_LP_ON=3                       # the rotation verify read swaps after printing
run_wd
unset FAKE_TMUX_SWAP_LP_ON
[ -e "$TS/sessions/orch-auto" ] && ok "rotation: the kill could not reach the replacement" || bad "kill landed on a replacement session"
[ -e "$WDIR/session-id" ] && ok "rotation: state kept after the failed id-bound kill" || bad "ownership state erased after a failed kill"

echo "== W21: HALT landing during the idle-alert barrier detection — no record touched, no raise"
reset; open_row
run_wd                                              # launch
echo "$(( $(date +%s) - 30000 ))" > "$WDIR/last-run"
printf 'ts=1\ntype=idle\nmsg=old\nsent=1\n' > "$WDIR/ALERT-idle"   # expired: the dedup decision says delete
rm -f "$FAKE_PS_COUNT"
export FAKE_PS_MAKE_HALT="$R/.orchestrator/HALT" FAKE_PS_MAKE_HALT_ON=2
run_wd                                              # entry detection clean; the idle barrier read injects HALT
unset FAKE_PS_MAKE_HALT FAKE_PS_MAKE_HALT_ON
grep -q '^sent=1' "$WDIR/ALERT-idle" && ok "mid-barrier HALT: expired idle record neither deleted nor re-raised" || bad "idle record touched despite HALT"
rm -f "$R/.orchestrator/HALT"

if [ "$fails" -eq 0 ]; then echo "PASS auto_resume_watchdog.sh"; else echo "FAIL auto_resume_watchdog.sh"; exit 1; fi
