#!/usr/bin/env bash
# R77 / PLAN-007 earliest falsifiable proof: the DISPOSABLE lifecycle falsifier. Everything runs
# under one mktemp root against tests/lifecycle/proto.sh (the throwaway prototype) and a
# long-lived interactive surrogate in a uniquely named tmux session — no production settings,
# ledger, credentials, sessions, or `claude -p` anywhere. Scenarios follow the brief's list:
# race, mapping, soft-trip, boundary handoff, successor + duplicate suppression, expiry fencing,
# HALT at every mutation, crash matrix, doom-loop dead-letter, safety dead-letter,
# liveness/kill discipline, rollback/teardown. Each positive case has a paired adverse case.
# Box-precondition skip contract (loud 77) when tmux is absent — a skip is never a pass.
set -uo pipefail
cd "$(dirname "$0")/.."

command -v tmux >/dev/null 2>&1 || { echo "SKIP lifecycle_falsifier.sh: tmux absent (box-only falsifier)"; exit 77; }
command -v flock >/dev/null 2>&1 || { echo "SKIP lifecycle_falsifier.sh: flock absent"; exit 77; }

fails=0
check() { # $1 name, $2 rc (0 ok)
    if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=1; fi
}

ROOT=$(mktemp -d)
TMUX_SESSION="lf-falsifier-$$-$RANDOM"
trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null; rm -rf "$ROOT"' EXIT

# manifest: prove throwaway isolation up front (temporary root, fake credentials, unique tmux
# namespace, zero production paths) — Gate 2's deterministic half.
mkdir -p "$ROOT/fake-home/.claude"
echo 'fake-credential-material' > "$ROOT/fake-home/.claude/.credentials.json"
{
    echo "root=$ROOT"
    echo "tmux_session=$TMUX_SESSION"
    echo "credentials=fake ($ROOT/fake-home)"
    echo "production_paths_written=none (asserted below)"
} > "$ROOT/manifest"

. tests/lifecycle/proto.sh
lf_init "$ROOT/state"

# ---- interactive surrogate (long-lived foreground process in tmux; NEVER claude -p) ----------
cat > "$ROOT/surrogate.sh" <<'SURR'
#!/usr/bin/env bash
# Long-lived interactive surrogate: reads commands from a FIFO like a foreground session,
# can spawn controlled child work, self-stops on request.
set -u
FIFO="$1"; OUT="$2"
while IFS= read -r cmd < "$FIFO"; do
    case "$cmd" in
        work)  ( sleep 0.2; echo "child-work-done" >> "$OUT" ) & wait ;;
        ping)  echo pong >> "$OUT" ;;
        stop)  echo stopped >> "$OUT"; exit 0 ;;
    esac
done
SURR
chmod +x "$ROOT/surrogate.sh"
mkfifo "$ROOT/cmds"
tmux new-session -d -s "$TMUX_SESSION" "HOME='$ROOT/fake-home' '$ROOT/surrogate.sh' '$ROOT/cmds' '$ROOT/events'"
sleep 0.3
tmux has-session -t "$TMUX_SESSION" 2>/dev/null; check "surrogate runs long-lived in its own tmux namespace" $?
echo work > "$ROOT/cmds"; sleep 0.6
grep -q child-work-done "$ROOT/events" 2>/dev/null; check "surrogate spawns and completes controlled child work (no claude -p)" $?

# ---- 1+2: two-session race — truly simultaneous, exactly one winner, exactly one mapped job ---
( lf_acquire ROW1 sessA 60 > "$ROOT/raceA" 2>/dev/null ) &
( lf_acquire ROW1 sessB 60 > "$ROOT/raceB" 2>/dev/null ) &
wait
winners=0 own="" gen=""
[ -s "$ROOT/raceA" ] && { winners=$((winners+1)); own=sessA; gen=$(cat "$ROOT/raceA"); }
[ -s "$ROOT/raceB" ] && { winners=$((winners+1)); own=sessB; gen=$(cat "$ROOT/raceB"); }
[ "$winners" -eq 1 ] && [ "$gen" = "1" ]; check "race: exactly one session acquires generation 1 (simultaneous, asserted from outputs)" $?
lf_start_job ROW1 "$own" "$gen" JOB1;                       check "winner starts exactly one mapped job" $?
lf_start_job ROW1 "$own" "$gen" JOB1 2>/dev/null; [ $? -eq 1 ]; check "duplicate job launch is suppressed (noclobber)" $?
loser=$( [ "$own" = sessA ] && echo sessB || echo sessA )
lf_start_job ROW1 "$loser" "$gen" JOB2 2>/dev/null; [ $? -eq 1 ]; check "loser cannot start a job (lease CAS refuses)" $?
grep -q "session=$own" "$ROOT/state/jobs/JOB1"; check "job record maps back to row, generation, owning session" $?

# ---- 3: soft trip never rotates mid-task ------------------------------------------------------
lf_soft_trip ROW1
lf_renew ROW1 "$own" "$gen" 60;                             check "soft trip: current owner keeps working (renew ok, no mid-task rotation)" $?
lf_start_job ROW1 "$own" "$gen" JOB-NEW 2>/dev/null; [ $? -eq 1 ]; check "soft trip: NEW acquisition refused until the safe boundary" $?

# ---- 4: safe boundary — atomic ledger-derived handoff + CAS release + self-stop ---------------
lf_commit_boundary ROW1 "$own" "$gen";                      check "boundary: handoff committed and lease released atomically" $?
grep -q '^source=ledger$' "$ROOT/state/handoffs/ROW1.gen$gen"; check "handoff is ledger-derived (source field), never a summary" $?
grep -q "jobs=JOB1" "$ROOT/state/handoffs/ROW1.gen$gen";    check "handoff carries the durable job map" $?
echo stop > "$ROOT/cmds"; sleep 0.4
grep -q stopped "$ROOT/events";                             check "owner session self-stops at the boundary" $?

# ---- 5: successor consumes ONCE, next generation, duplicates suppressed -----------------------
lf_consume_handoff ROW1 sessC;                              check "successor consumes the handoff" $?
lf_consume_handoff ROW1 sessD 2>/dev/null; [ $? -eq 1 ];    check "second consumption refused (one-time, atomic mv)" $?
g2=$(lf_acquire ROW1 sessC 60);                             check "successor acquires the next generation" $?
[ "$g2" -gt "$gen" ];                                       check "generation is monotonic across rotation" $?
lf_start_job ROW1 sessC "$g2" JOB1 2>/dev/null; [ $? -eq 1 ]; check "successor cannot duplicate the predecessor's job id" $?

# ---- 6: expiry — fresh session takes over, stale session fenced everywhere --------------------
g3=$(lf_acquire ROW2 sessOld 1); sleep 2
g4=$(lf_acquire ROW2 sessNew 60);                           check "expired lease: fresh session acquires next generation" $?
[ "$g4" -gt "$g3" ];                                        check "takeover raises the generation" $?
lf_renew   ROW2 sessOld "$g3" 60 2>/dev/null; [ $? -eq 1 ]; check "stale session refused: renew" $?
lf_release ROW2 sessOld "$g3"    2>/dev/null; [ $? -eq 1 ]; check "stale session refused: release" $?
lf_start_job ROW2 sessOld "$g3" JOBX 2>/dev/null; [ $? -eq 1 ]; check "stale session refused: job launch" $?
lf_commit_boundary ROW2 sessOld "$g3" 2>/dev/null; [ $? -eq 1 ]; check "stale session refused: handoff/closure" $?
# malformed + backward clock: corrupt expiry must refuse takeover, not grant it
sed -i 's/^expiry=.*/expiry=not-a-number/' "$ROOT/state/rows/ROW2.lease"
lf_acquire ROW2 sessEvil 60 >/dev/null 2>&1; [ $? -eq 1 ];  check "malformed expiry fails closed (no takeover)" $?
sed -i "s/^expiry=.*/expiry=$(( $(date +%s) + 60 ))/" "$ROOT/state/rows/ROW2.lease"

# ---- 7: HALT outranks every mutation -----------------------------------------------------------
: > "$ROOT/state/HALT"
for op in "lf_acquire ROW3 sessH 60" "lf_renew ROW2 sessNew $g4 60" "lf_release ROW2 sessNew $g4" \
          "lf_start_job ROW2 sessNew $g4 JOBH" "lf_soft_trip ROW2" "lf_compaction sessNew" \
          "lf_commit_boundary ROW2 sessNew $g4" "lf_consume_handoff ROW2 sessH" \
          "lf_respawn ROW2" "lf_safety_flag ROW2 $g4" "lf_kill_eligible sessNew id ROW2 $g4"; do
    $op >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 9 ] || { echo "FAIL HALT did not stop: $op (rc=$rc)"; fails=1; }
done
check "HALT refuses every mutation, prompt, rotation, dead-letter, and kill (rc 9)" $fails
rm -f "$ROOT/state/HALT"

# ---- 8: crash matrix — one owner or one visible next action, never two -------------------------
for point in before-lease-write after-lease-write before-handoff-write after-handoff-write \
             after-boundary-release before-consume after-consume before-job-write after-job-write \
             before-release after-release; do
    CR="$ROOT/crash-$point"; mkdir -p "$CR"
    ( . tests/lifecycle/proto.sh; lf_init "$CR"
      g=$(lf_acquire CROW s1 60) || g=""
      [ -n "$g" ] && lf_start_job CROW s1 "$g" CJOB >/dev/null 2>&1
      LF_CRASH_POINT=$point
      case "$point" in
        before-lease-write|after-lease-write) LF_ROOT="$CR" lf_acquire CROW2 s1 60 ;;
        before-job-write|after-job-write)     LF_ROOT="$CR" lf_start_job CROW s1 "$g" CJOB2 ;;
        before-release|after-release)         LF_ROOT="$CR" lf_release CROW s1 "$g" ;;
        before-consume|after-consume)         LF_ROOT="$CR" lf_commit_boundary CROW s1 "$g"; \
                                              LF_CRASH_POINT=$point LF_ROOT="$CR" lf_consume_handoff CROW s2 ;;
        *)                                    LF_ROOT="$CR" lf_commit_boundary CROW s1 "$g" ;;
      esac
    ) >/dev/null 2>&1
    # recovery must produce exactly one unambiguous answer and no stray temp files
    out=$(LF_ROOT="$CR" lf_recover CROW)
    case "$out" in owner\ *|handoff-ready|released) rc=0 ;; *) rc=1 ;; esac
    stray=$(find "$CR" -name '.tmp.*' | wc -l)
    [ "$rc" -eq 0 ] && [ "$stray" -eq 0 ] || { echo "FAIL crash@$point: recover='$out' stray=$stray"; fails=1; }
done
check "crash matrix: every crash point recovers to ONE owner/next action, no trusted partials" $fails

# ---- 9: doom loop — third activity-free respawn dead-letters, no fourth -----------------------
lf_respawn ROW4; lf_respawn ROW4
lf_activity ROW4                                       # recorded activity resets the counter
lf_respawn ROW4; lf_respawn ROW4
lf_respawn ROW4; rc=$?; [ "$rc" -eq 3 ];                    check "third consecutive activity-free respawn dead-letters (rc 3)" $?
[ -e "$ROOT/state/deadletters/ROW4" ];                      check "dead-letter record exists for the doomed row" $?
lf_respawn ROW4 2>/dev/null; [ $? -eq 3 ];                  check "no fourth automatic respawn (dead-letter is sticky)" $?
lf_acquire ROW4 sessZ 60 >/dev/null 2>&1; [ $? -eq 3 ];     check "a dead-lettered row cannot be re-acquired automatically" $?

# ---- 10: safety flag — immediate dead-letter, bound to row+generation --------------------------
g5=$(lf_acquire ROW5 sessS 60)
lf_safety_flag ROW5 "$((g5 + 7))" 2>/dev/null; [ $? -eq 1 ]; check "safety flag with a wrong generation refuses (never a fresh/other lease)" $?
lf_safety_flag ROW5 "$g5";                                  check "safety-flagged turn dead-letters immediately" $?
lf_start_job ROW5 sessS "$g5" JOBS 2>/dev/null; [ $? -eq 3 ]; check "no further row action after a safety dead-letter" $?

# ---- 11+12: liveness/kill discipline ------------------------------------------------------------
g6=$(lf_acquire ROW6 sessK 60)
lf_observe sessK stale tmux-id-1
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]; check "ONE stale observation cannot kill" $?
lf_observe sessK unknown tmux-id-1
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]; check "unknown-class evidence cannot kill" $?
lf_observe sessK stale tmux-id-1
lf_kill_eligible sessK tmux-id-OTHER ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]; check "ownership/identity mismatch cannot kill" $?
: > "$ROOT/state/foreign-claude"
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]; check "foreign-Claude presence (standby) cannot kill or type" $?
rm -f "$ROOT/state/foreign-claude"
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6";                check "repeated classified evidence for the verified identity IS kill-eligible" $?
lf_kill_eligible sessK tmux-id-1 ROW6 "$((g6 + 1))" 2>/dev/null; [ $? -eq 1 ]; check "kill eligibility binds to the exact lease generation" $?

# ---- N=1 compaction ceiling ---------------------------------------------------------------------
lf_compaction sessK
lf_acquire ROW7 sessK 60 >/dev/null 2>&1; [ $? -eq 1 ];     check "one classified compaction: the session acquires no further row (N=1)" $?
lf_acquire ROW7 sessFresh 60 >/dev/null;                    check "a fresh session still acquires the row (ceiling is per-session)" $?

# ---- 13: rollback/teardown — nothing lives on, nothing production was touched ------------------
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null
tmux has-session -t "$TMUX_SESSION" 2>/dev/null; [ $? -ne 0 ]; check "rollback: no live surrogate remains" $?
# the prototype only ever wrote under $ROOT: prove the repo tree is untouched by this run
dirty=$(git status --porcelain -- . ':!tests/lifecycle' ':!tests/lifecycle_falsifier.sh' | wc -l)
[ "$dirty" -eq 0 ];                                          check "rollback: no production path was written (repo tree clean)" $?
sha256sum "$ROOT/manifest" > "$ROOT/manifest.sha256"
echo "manifest: $(cat "$ROOT/manifest.sha256")"

if [ "$fails" -ne 0 ]; then echo "FAIL lifecycle_falsifier.sh"; exit 1; fi
echo "PASS lifecycle_falsifier.sh"
