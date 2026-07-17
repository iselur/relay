#!/usr/bin/env bash
# Hermetic gate for flag-gated lifecycle behavior. Fixtures own every output and filename below.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
ok() { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
R="$tmp/root"; F="$tmp/fakes"; T="$tmp/tmux"
mkdir -p "$R/scripts/lib" "$R/.orchestrator" "$F" "$T/sessions"
cp scripts/watchdog "$R/scripts/watchdog"
cp scripts/lib/watchdog-resume-prompt.txt "$R/scripts/lib/watchdog-resume-prompt.txt"

cat > "$R/scripts/intake" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  watchdog-state)
    if [ -n "$FAKE_INTAKE_IDS" ]; then echo "$FAKE_INTAKE_STATE $FAKE_INTAKE_IDS"; else echo "$FAKE_INTAKE_STATE"; fi ;;
  *) exit 2 ;;
esac
FAKE

cat > "$F/tmux" <<'FAKE'
#!/usr/bin/env bash
S="$FAKE_TMUX_STATE"
echo "tmux $*" >> "$S/invocations.log"
cmd=$1; shift; target=""; args=()
while (($#)); do
  case "$1" in
    -t|-s) target=$2; shift 2 ;;
    -F|-c|-x|-y) shift 2 ;;
    -d|-o|-p|-P) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
resolve() {
  case "$target" in
    '$'*|'%'*)
      field=1
      case "$target" in %*) field=4;; esac
      for p in "$S/sessions/"*.pane; do
        [ -e "$p" ] || continue
        [ "$(head -1 "$p" | cut -d: -f"$field")" = "$target" ] && target=orch-auto && return 0
      done
      return 1 ;;
  esac
}
case "$cmd" in
  has-session) [ -e "$S/sessions/$target" ] ;;
  new-session)
    [ ! -e "$S/sessions/$target" ] || exit 1
    touch "$S/sessions/$target"; echo bash > "$S/sessions/$target.cmd"
    printf '$0:100:500:%%5\n' > "$S/sessions/$target.pane"
    printf '$0:100:500:%%5\n' ;;
  display-message) cat "$S/sessions/$target.cmd" 2>/dev/null || echo bash ;;
  list-panes) resolve || exit 1; cat "$S/sessions/$target.pane" 2>/dev/null || exit 1 ;;
  send-keys) resolve || exit 1; printf '%s\n' "${args[*]}" >> "$S/sessions/$target.keys"; echo claude > "$S/sessions/$target.cmd" ;;
  pipe-pane) resolve || exit 1 ;;
  kill-session) resolve || exit 1; rm -f "$S/sessions/$target" "$S/sessions/$target."* ;;
  *) exit 1 ;;
esac
FAKE

cat > "$F/ps" <<'FAKE'
#!/usr/bin/env bash
n=$(cat "$FAKE_PS_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_PS_COUNT"
if [ "$FAKE_FOREIGN" = 1 ]; then printf '900 1 claude\n'; fi
FAKE

cat > "$F/pgrep" <<'FAKE'
#!/usr/bin/env bash
# Required companion fixture: presence tests pin pgrep as well as ps/tmux.
[ "$1" = "-x" ] && [ "$2" = "claude" ] && [ "$FAKE_FOREIGN" = 1 ] && echo 900
FAKE

cat > "$F/uuidgen" <<'FAKE'
#!/usr/bin/env bash
n=$(cat "$FAKE_UUID_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_UUID_COUNT"
printf '00000000-0000-4000-8000-%012d\n' "$n"
FAKE
chmod +x "$R/scripts/intake" "$F"/*

WD="$R/.orchestrator/watchdog"
export FAKE_TMUX_STATE="$T" FAKE_PS_COUNT="$tmp/ps-count" FAKE_UUID_COUNT="$tmp/uuid-count"
run_wd() { PATH="$F:$PATH" ORCH_ROOT="$R" ORCH_WATCHDOG_DIR="$WD" ORCH_TMUX_SESSION=orch-auto bash "$R/scripts/watchdog" check >/dev/null 2>&1; }
reset() {
  rm -rf "$WD" "$T/sessions" "$R/.orchestrator/HALT"; mkdir -p "$T/sessions"
  rm -f "$FAKE_PS_COUNT" "$FAKE_UUID_COUNT" "$T/invocations.log"
  FAKE_FOREIGN=0
  export FAKE_INTAKE_STATE=PENDING FAKE_INTAKE_IDS=R81
}
active() { mkdir -p "$WD"; : > "$WD/lifecycle-active"; }
dead() { echo bash > "$T/sessions/orch-auto.cmd"; }
launch_then_dead() { run_wd; dead; }
keys() { cat "$T/sessions/orch-auto.keys" 2>/dev/null || true; }
key_count() { keys | wc -l; }
has() { [ -e "$1" ]; }

echo "== R1: marker + dead pane uses a fresh launch and consumes the marker"
reset; active; launch_then_dead; : > "$WD/rotation-requested"; run_wd
grep -q -- '--session-id 00000000-0000-4000-8000-000000000002' <(keys) && ok "fresh session launched after marker" || bad "fresh session was not launched"
! grep -q -- '--resume' <(keys) && ok "rotation did not resume the old session" || bad "rotation resumed the old session"
! has "$WD/rotation-requested" && ok "rotation marker consumed" || bad "rotation marker remained"

echo "== R2: dead pane without marker keeps the exact resume fallback"
reset; launch_then_dead; run_wd
grep -q -- '--resume 00000000-0000-4000-8000-000000000001' <(keys) && ok "dead pane resumed the recorded id" || bad "resume fallback changed"

echo "== R3: failed ownership quarantines the marker and does not launch"
reset; active; launch_then_dead; : > "$WD/rotation-requested"
printf '$7:900:800:%%9\n' > "$T/sessions/orch-auto.pane"
before=$(key_count); run_wd
[ "$(key_count)" = "$before" ] && ok "ownership failure sent no keys" || bad "ownership failure launched"
! has "$WD/rotation-requested" && compgen -G "$WD/rotation-requested.quarantined.*" >/dev/null && ok "marker was renamed aside" || bad "marker was not quarantined"
has "$WD/ALERT-rotation-quarantine" && ok "rotation quarantine raised the pinned alert" || bad "rotation quarantine alert missing"

echo "== R4: third fruitless respawn dead-letters, blocks the fourth, and resets the counter"
reset; active; launch_then_dead
run_wd; dead; run_wd; dead; run_wd
has "$WD/dead-letter" && ok "third respawn wrote dead-letter" || bad "third respawn did not dead-letter"
[ "$(cat "$WD/respawns")" = 0 ] && ok "dead-letter reset the respawn counter" || bad "dead-letter kept the counter"
grep -q '^rows=R81$' "$WD/dead-letter" && ok "dead-letter pins the intake row id" || bad "dead-letter row id missing"
has "$WD/ALERT-dead-letter" && ok "dead-letter raised the pinned alert" || bad "dead-letter alert missing"
before=$(key_count); dead; run_wd; [ "$(key_count)" = "$before" ] && ok "fourth respawn was refused" || bad "fourth respawn was sent"

echo "== R5: safety flag dead-letters immediately and preserves its content"
reset; active; launch_then_dead; printf 'turn=R81\nreason=unsafe output\n' > "$WD/safety-flagged"; before=$(key_count); run_wd
[ "$(key_count)" = "$before" ] && ok "safety flag sent no respawn" || bad "safety flag respawned"
has "$WD/dead-letter" && ok "safety flag wrote dead-letter" || bad "safety flag did not dead-letter"
grep -q 'turn=R81' "$WD/dead-letter" && grep -q 'reason=unsafe output' "$WD/dead-letter" && ok "safety content was preserved" || bad "safety content was lost"

echo "== R6: HALT wins over launch, rotation, and dead-letter"
reset; active; touch "$R/.orchestrator/HALT"; run_wd
! has "$T/sessions/orch-auto" && ok "HALT blocked fresh launch" || bad "HALT did not block fresh launch"
reset; active; launch_then_dead; : > "$WD/rotation-requested"; touch "$R/.orchestrator/HALT"; before=$(key_count); run_wd
[ "$(key_count)" = "$before" ] && ! has "$WD/dead-letter" && ok "HALT blocked rotation" || bad "HALT did not block rotation"
reset; active; launch_then_dead; printf 2 > "$WD/respawns"; touch "$R/.orchestrator/HALT"; before=$(key_count); run_wd
[ "$(key_count)" = "$before" ] && ! has "$WD/dead-letter" && ok "HALT blocked dead-letter" || bad "HALT did not block dead-letter"

echo "== R7: standby parks rotation, dead-letter, and safety branches"
reset; active; launch_then_dead; : > "$WD/rotation-requested"; export FAKE_FOREIGN=1; before=$(key_count); run_wd
[ "$(key_count)" = "$before" ] && ! compgen -G "$WD/rotation-requested.quarantined.*" >/dev/null && ok "standby parked rotation" || bad "standby acted on rotation"
reset; active; launch_then_dead; printf 2 > "$WD/respawns"; export FAKE_FOREIGN=1; before=$(key_count); run_wd
[ "$(key_count)" = "$before" ] && ! has "$WD/dead-letter" && ok "standby parked dead-letter" || bad "standby acted on dead-letter"
reset; active; launch_then_dead; printf safety > "$WD/safety-flagged"; export FAKE_FOREIGN=1; before=$(key_count); run_wd
[ "$(key_count)" = "$before" ] && ! has "$WD/dead-letter" && ok "standby parked safety handling" || bad "standby acted on safety"

echo "== R8: shadow mode logs decisions but preserves existing behavior"
reset; launch_then_dead; : > "$WD/rotation-requested"; run_wd
grep -Eq '^ts=[0-9]+ event=rotation_would_fire ' "$WD/lifecycle-shadow.log" && ok "shadow rotation decision logged with a timestamp" || bad "shadow rotation was not logged"
grep -q -- '--resume 00000000-0000-4000-8000-000000000001' <(keys) && ok "shadow rotation retained resume fallback" || bad "shadow rotation changed fallback"
reset; launch_then_dead; printf 2 > "$WD/respawns"; run_wd; dead; run_wd
grep -Eq '^ts=[0-9]+ event=deadletter_would_fire ' "$WD/lifecycle-shadow.log" && ok "shadow dead-letter decision logged with a timestamp" || bad "shadow dead-letter was not logged"
! has "$WD/dead-letter" && ok "shadow mode did not dead-letter" || bad "shadow mode dead-lettered"
reset; launch_then_dead; printf safety > "$WD/safety-flagged"; run_wd
grep -Eq '^ts=[0-9]+ event=safety_would_fire ' "$WD/lifecycle-shadow.log" && ok "shadow safety decision logged with a timestamp" || bad "shadow safety was not logged"
grep -q -- '--resume 00000000-0000-4000-8000-000000000001' <(keys) && ok "shadow safety retained existing resume behavior" || bad "shadow safety changed fallback"
! has "$WD/dead-letter" && ok "shadow safety did not dead-letter" || bad "shadow safety dead-lettered"

[ "$fails" -eq 0 ] && echo "PASS rotation.sh" || { echo "FAIL rotation.sh"; exit 1; }
