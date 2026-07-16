#!/usr/bin/env bash
# R77 / PLAN-007 earliest falsifiable proof — round-2 revision of the DISPOSABLE lifecycle
# falsifier. Drives tests/lifecycle/proto.sh (the throwaway prototype) plus a long-lived
# interactive surrogate on a PRIVATE tmux socket. Nothing touches production paths, credentials,
# sessions, or `claude -p`. Every positive case has adverse pairs; every scenario from the
# brief's list runs: barrier-synchronized race, session<->job mapping BOTH directions,
# soft-trip boundary discipline (acquire AND job refused), atomic single-transaction handoff
# consumption, expiry fencing incl. malformed AND backward clocks, HALT at entry and at every
# write boundary for EVERY mutator, a crash matrix whose every point recovers to ONE owner or
# ONE recorded next action, doom-loop/safety dead-letters fencing ALL mutations, kill discipline
# (distinct ticks, unknown-veto, generation binding, standby TOCTOU at the action), N=1 ceiling
# semantics (no new rows, no new jobs, boundary handoff still allowed), id sanitization, and an
# explicit teardown that removes everything and proves the repo tree untouched. Emits a POST-run
# result manifest binding artifact digests, per-scenario results, timestamps, exit status, and
# teardown outcome. Loud-SKIP (77) box contract when tmux is absent — a skip is never a pass.
set -uo pipefail
cd "$(dirname "$0")/.."

command -v tmux  >/dev/null 2>&1 || { echo "SKIP lifecycle_falsifier.sh: tmux absent (box-only falsifier)"; exit 77; }
command -v flock >/dev/null 2>&1 || { echo "SKIP lifecycle_falsifier.sh: flock absent"; exit 77; }

START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fails=0
RESULTS=()
check() { # $1 name, $2 rc (0 ok)
    if [ "$2" -eq 0 ]; then echo "ok   $1"; RESULTS+=("ok   $1"); else echo "FAIL $1"; RESULTS+=("FAIL $1"); fails=1; fi
}

ROOT=$(mktemp -d)
SOCK="lf-$$"                                   # PRIVATE tmux server (own socket), not the default
TMUX_SESSION="lf-falsifier-$$-$RANDOM"
STAMP="$ROOT/repo-stamp"; touch "$STAMP"; sleep 0.05
trap 'tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/fake-home/.claude"
echo 'fake-credential-material' > "$ROOT/fake-home/.claude/.credentials.json"

. tests/lifecycle/proto.sh
lf_init "$ROOT/state" supervisor-token

# ---- interactive surrogate (long-lived, private tmux server; NEVER claude -p) -----------------
cat > "$ROOT/surrogate.sh" <<'SURR'
#!/usr/bin/env bash
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
tmux -L "$SOCK" new-session -d -s "$TMUX_SESSION" "HOME='$ROOT/fake-home' '$ROOT/surrogate.sh' '$ROOT/cmds' '$ROOT/events'"
sleep 0.3
tmux -L "$SOCK" has-session -t "$TMUX_SESSION" 2>/dev/null
check "surrogate runs long-lived on a PRIVATE tmux socket (isolated server)" $?
tmux has-session -t "$TMUX_SESSION" 2>/dev/null; [ $? -ne 0 ]
check "the default tmux server never sees the surrogate" $?
echo work > "$ROOT/cmds"; sleep 0.6
grep -q child-work-done "$ROOT/events" 2>/dev/null
check "surrogate spawns and completes controlled child work (no claude -p anywhere)" $?

# ---- id sanitization: path escapes refuse before any filesystem touch --------------------------
lf_acquire "../evil" sessA 60 >/dev/null 2>&1; [ $? -eq 1 ];   check "row id '../evil' refuses (no LF_ROOT escape)" $?
lf_acquire ROWX "../evil" 60 >/dev/null 2>&1; [ $? -eq 1 ];    check "session id '../evil' refuses" $?
g0=$(lf_acquire ROWX sessA 60)
lf_start_job ROWX sessA "$g0" "../../evil" 2>/dev/null; [ $? -eq 1 ]; check "job id '../../evil' refuses" $?
[ ! -e "$ROOT/evil" ] && [ ! -e "$(dirname "$ROOT")/evil" ];   check "no escaped file was created" $?
lf_release ROWX sessA "$g0"

# ---- 1+2: BARRIER-synchronized race — exactly one winner, exactly one mapped job ---------------
: > "$ROOT/blockA"; : > "$ROOT/blockB"
( until [ -e "$ROOT/go" ]; do :; done; lf_acquire ROW1 sessA 60 > "$ROOT/raceA" 2>/dev/null; rm "$ROOT/blockA" ) &
( until [ -e "$ROOT/go" ]; do :; done; lf_acquire ROW1 sessB 60 > "$ROOT/raceB" 2>/dev/null; rm "$ROOT/blockB" ) &
sleep 0.2; : > "$ROOT/go"   # both racers spin at the barrier, then release together
wait
winners=0 own="" gen=""
[ -s "$ROOT/raceA" ] && { winners=$((winners+1)); own=sessA; gen=$(cat "$ROOT/raceA"); }
[ -s "$ROOT/raceB" ] && { winners=$((winners+1)); own=sessB; gen=$(cat "$ROOT/raceB"); }
[ "$winners" -eq 1 ] && [ "$gen" = "1" ]
check "race: barrier-released simultaneous acquires — exactly one wins generation 1" $?
loser=$( [ "$own" = sessA ] && echo sessB || echo sessA )
lf_acquire ROW1 "$own" 60 >/dev/null 2>&1; [ $? -eq 1 ]
check "the LIVE owner cannot re-acquire its own row (renew is the only path — no gen bump)" $?
lf_start_job ROW1 "$own" "$gen" JOB1;                          check "winner starts exactly one mapped job" $?
lf_start_job ROW1 "$own" "$gen" JOB1 2>/dev/null; [ $? -eq 1 ]; check "duplicate job launch refuses (atomic create-once)" $?
lf_start_job ROW1 "$loser" "$gen" JOB2 2>/dev/null; [ $? -eq 1 ]; check "loser cannot start a job (lease CAS)" $?
grep -q "session=$own" "$ROOT/state/jobs/JOB1";                check "forward trace: job names row, generation, session" $?
[ "$(lf_jobs_of_lease ROW1 "$gen")" = "JOB1" ];                check "reverse trace: the lease lists exactly the jobs it authorized" $?

# ---- 3: soft trip — owner-only request; no mid-task rotation; acquire AND new jobs refuse ------
lf_soft_trip ROW1 "$loser" "$gen" 2>/dev/null; [ $? -eq 1 ];   check "a non-owner cannot request rotation (CAS)" $?
lf_soft_trip ROW1 "$own" "$gen";                               check "the owner requests rotation at a soft threshold" $?
lf_renew ROW1 "$own" "$gen" 60;                                check "soft trip: current task continues (renew ok — no mid-task rotation)" $?
lf_start_job ROW1 "$own" "$gen" JOB-NEW 2>/dev/null; [ $? -eq 1 ]; check "soft trip: NEW job refused until the boundary" $?
lf_acquire ROW1 sessC 60 >/dev/null 2>&1; [ $? -eq 1 ];        check "soft trip: NEW acquisition refused (live lease + rotate marker both fence)" $?

# ---- 4: safe boundary — atomic ledger-derived handoff + release + self-stop --------------------
lf_commit_boundary ROW1 "$own" "$gen";                         check "boundary: handoff committed and lease released in one locked transaction" $?
lf_acquire ROW1 sessE 60 >/dev/null 2>&1; [ $? -eq 1 ];        check "an unconsumed handoff fences bare acquisition (continuity goes to a successor)" $?
grep -q '^source=ledger$' "$ROOT/state/handoffs/ROW1.gen$gen"; check "handoff declares its ledger derivation" $?
grep -q "jobs=JOB1" "$ROOT/state/handoffs/ROW1.gen$gen";       check "handoff carries the durable job map (from the reverse trace, not prose)" $?
echo stop > "$ROOT/cmds"; sleep 0.4
grep -q stopped "$ROOT/events";                                check "owner session self-stops at the boundary" $?

# ---- 5: successor — single-transaction consumption, next generation, duplicates refused --------
g2=$(lf_consume_handoff ROW1 sessC);                           check "successor consumes handoff AND receives its lease in ONE transaction" $?
[ "$g2" -gt "$gen" ];                                          check "generation is monotonic across rotation" $?
lf_consume_handoff ROW1 sessD 2>/dev/null; [ $? -eq 1 ];       check "second consumption refuses (handoff is gone, lease is live)" $?
lf_start_job ROW1 sessC "$g2" JOB1 2>/dev/null; [ $? -eq 1 ];  check "successor cannot duplicate the predecessor's job id" $?
g_pre=$(lf_acquire ROWP sessP 60); lf_start_job ROWP sessP "$g_pre" JOBP
lf_consume_handoff ROWP sessQ 2>/dev/null; [ $? -eq 1 ];       check "consumption refuses while the from-lease is still LIVE (no dual authority)" $?
lf_release ROWP sessP "$g_pre"

# ---- 6: expiry + clock discipline ---------------------------------------------------------------
g3=$(lf_acquire ROW2 sessOld 1); sleep 2
g4=$(lf_acquire ROW2 sessNew 60);                              check "expired lease: fresh session acquires the next generation" $?
[ "$g4" -gt "$g3" ];                                           check "takeover raises the generation" $?
for op in "lf_renew ROW2 sessOld $g3 60" "lf_release ROW2 sessOld $g3" \
          "lf_start_job ROW2 sessOld $g3 JOBX" "lf_commit_boundary ROW2 sessOld $g3" \
          "lf_soft_trip ROW2 sessOld $g3" "lf_activity ROW2 sessOld $g3" \
          "lf_safety_flag ROW2 sessOld $g3"; do
    $op >/dev/null 2>&1; [ $? -eq 1 ] || { echo "FAIL stale session not refused: $op"; fails=1; }
done
check "stale session refused at EVERY fenced operation (renew/release/job/boundary/trip/activity/safety)" $fails
sed -i 's/^expiry=.*/expiry=not-a-number/' "$ROOT/state/rows/ROW2.lease"
lf_acquire ROW2 sessEvil 60 >/dev/null 2>&1; [ $? -eq 1 ];     check "malformed expiry fails closed (a corrupt lease fences, never grants)" $?
sed -i "s/^expiry=.*/expiry=$(( $(date +%s) + 60 ))/" "$ROOT/state/rows/ROW2.lease"
echo $(( $(date +%s) + 99999 )) > "$ROOT/state/.last_now"      # clock moved BACKWARD vs floor
lf_acquire ROW-CLK sessA 60 >/dev/null 2>&1; [ $? -eq 1 ];     check "backward clock: acquisition refuses (monotonic floor)" $?
lf_renew ROW2 sessNew "$g4" 60 2>/dev/null; [ $? -eq 1 ];      check "backward clock: renew refuses too (no mutation on bad time)" $?
echo 0 > "$ROOT/state/.last_now"

# ---- 7: HALT — entry AND write-boundary, for EVERY mutator ---------------------------------------
: > "$ROOT/state/HALT"
halt_fails=0
for op in "lf_acquire ROW3 sessH 60" "lf_renew ROW2 sessNew $g4 60" "lf_release ROW2 sessNew $g4" \
          "lf_start_job ROW2 sessNew $g4 JOBH" "lf_soft_trip ROW2 sessNew $g4" \
          "lf_compaction sessNew" "lf_commit_boundary ROW2 sessNew $g4" \
          "lf_consume_handoff ROW2 sessH" "lf_respawn ROW2 supervisor-token" \
          "lf_activity ROW2 sessNew $g4" "lf_safety_flag ROW2 sessNew $g4" \
          "lf_observe sessNew stale id ROW2 $g4 t1" "lf_kill_eligible sessNew id ROW2 $g4" \
          "lf_kill sessNew id ROW2 $g4" "lf_type sessNew hello" "lf_recover_finish ROW2"; do
    $op >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 9 ] || { echo "FAIL HALT did not stop: $op (rc=$rc)"; halt_fails=1; }
done
check "HALT refuses EVERY mutator incl. observe/activity/type/kill/recover (rc 9)" $halt_fails
( . tests/lifecycle/proto.sh; LF_ROOT="$ROOT/state"; _lf_write "$ROOT/state/should-not-exist" <<< x ) 2>/dev/null
[ $? -eq 9 ] && [ ! -e "$ROOT/state/should-not-exist" ]
check "HALT is re-checked at the WRITE boundary itself (mid-operation arrival still stops)" $?
rm -f "$ROOT/state/HALT"

# ---- 8: crash matrix — ONE owner or ONE recorded next action at every point ---------------------
crash_fails=0
crash_case() {  # $1 point, $2 op-description; runs a fresh root per point
    local point=$1 CR="$ROOT/crash-$point"
    mkdir -p "$CR"
    (
        . tests/lifecycle/proto.sh; lf_init "$CR" sup
        case "$point" in
            before-lease-write|after-lease-write)
                LF_CRASH_POINT=$point lf_acquire CROW s1 60 ;;
            before-job-write|after-job-write)
                g=$(lf_acquire CROW s1 60); LF_CRASH_POINT=$point lf_start_job CROW s1 "$g" CJOB ;;
            before-release|after-release)
                g=$(lf_acquire CROW s1 60); LF_CRASH_POINT=$point lf_release CROW s1 "$g" ;;
            before-handoff-write|after-handoff-write|after-boundary-release)
                g=$(lf_acquire CROW s1 60); lf_start_job CROW s1 "$g" CJOB
                LF_CRASH_POINT=$point lf_commit_boundary CROW s1 "$g" ;;
            before-consume|after-consume|after-successor-lease)
                g=$(lf_acquire CROW s1 60); lf_commit_boundary CROW s1 "$g"
                LF_CRASH_POINT=$point lf_consume_handoff CROW s2 ;;
        esac
    ) >/dev/null 2>&1
    local out rc=0
    out=$(LF_ROOT="$CR" lf_recover CROW)
    case "$out" in
        owner\ *|handoff-ready|released) ;;
        consumed-by\ s2)
            # the recorded successor — and ONLY it — completes the interrupted consumption
            local fin
            fin=$(LF_ROOT="$CR" lf_recover_finish CROW) || rc=1
            [ "$fin" = "s2" ] || rc=1
            [ "$(LF_ROOT="$CR" lf_recover CROW)" = "owner s2" ] || rc=1 ;;
        *) rc=1 ;;
    esac
    local stray; stray=$(find "$CR" -name '.tmp.*' | wc -l)
    { [ "$rc" -eq 0 ] && [ "$stray" -eq 0 ]; } || { echo "FAIL crash@$point: recover='$out' stray=$stray"; crash_fails=1; }
}
for point in before-lease-write after-lease-write before-job-write after-job-write \
             before-release after-release before-handoff-write after-handoff-write \
             after-boundary-release before-consume after-consume after-successor-lease; do
    crash_case "$point"
done
check "crash matrix (12 points): every recovery is ONE owner or ONE recorded next action, no stray temps" $crash_fails
# ambiguity probe: a crash after handoff-write leaves the from-lease LIVE — the handoff must be
# unconsumable until release, so there is never simultaneous owner+consumable-handoff authority
CR="$ROOT/crash-after-handoff-write"
LF_ROOT="$CR" lf_consume_handoff CROW s3 >/dev/null 2>&1; [ $? -eq 1 ]
check "owner+handoff coexistence is NOT dual authority: consumption refuses while the lease is live" $?

# ---- 9: doom loop — supervisor-only counting, durable, three strikes ----------------------------
lf_respawn ROW4 wrong-token 2>/dev/null; [ $? -eq 1 ];         check "respawn counting requires the supervisor token" $?
lf_respawn ROW4 supervisor-token; lf_respawn ROW4 supervisor-token
g7=$(lf_acquire ROW4 sessR 60)
lf_activity ROW4 sessR "$g7"                                    # owner records useful activity
lf_respawn ROW4 supervisor-token; lf_respawn ROW4 supervisor-token
lf_respawn ROW4 supervisor-token; [ $? -eq 3 ];                check "third consecutive activity-free respawn dead-letters (rc 3)" $?
lf_respawn ROW4 supervisor-token 2>/dev/null; [ $? -eq 3 ];    check "no fourth automatic respawn (dead-letter is sticky)" $?
dl_fails=0
for op in "lf_acquire ROW4 sessZ 60" "lf_renew ROW4 sessR $g7 60" "lf_release ROW4 sessR $g7" \
          "lf_start_job ROW4 sessR $g7 JOBD" "lf_commit_boundary ROW4 sessR $g7" \
          "lf_soft_trip ROW4 sessR $g7" "lf_activity ROW4 sessR $g7" "lf_consume_handoff ROW4 sessZ"; do
    $op >/dev/null 2>&1; [ $? -eq 3 ] || { echo "FAIL dead-letter did not fence: $op"; dl_fails=1; }
done
check "a dead-lettered row fences EVERY mutation (acquire/renew/release/job/boundary/trip/activity/consume)" $dl_fails

# ---- 10: safety flag — immediate, full-CAS-bound dead-letter ------------------------------------
g5=$(lf_acquire ROW5 sessS 60)
lf_safety_flag ROW5 sessS "$((g5 + 7))" 2>/dev/null; [ $? -eq 1 ]; check "safety flag with a wrong generation refuses" $?
lf_safety_flag ROW5 sessOther "$g5" 2>/dev/null; [ $? -eq 1 ];  check "safety flag from a non-owner session refuses (full CAS)" $?
lf_safety_flag ROW5 sessS "$g5";                                check "safety-flagged turn dead-letters immediately" $?
lf_start_job ROW5 sessS "$g5" JOBS 2>/dev/null; [ $? -eq 3 ];   check "no further row action after a safety dead-letter" $?
[ ! -e "$ROOT/state/deadletters/ROW6" ];                        check "the safety flag cannot touch a different row (row-bound record)" $?

# ---- 11+12: kill discipline ----------------------------------------------------------------------
g6=$(lf_acquire ROW6 sessK 600)
lf_observe sessK stale tmux-id-1 ROW6 "$g6" t1
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]; check "ONE stale observation cannot kill" $?
lf_observe sessK stale tmux-id-1 ROW6 "$g6" t1 2>/dev/null      # same tick again
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]; check "two observations on the SAME tick cannot kill (distinct ticks required)" $?
lf_observe sessK unknown tmux-id-1 ROW6 "$g6" t2
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]; check "an intervening 'unknown' vetoes (last two must both be classified stale)" $?
lf_observe sessK stale tmux-id-1 ROW6 "$g6" t3
lf_observe sessK stale tmux-id-OTHER ROW6 "$g6" t4
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]; check "an identity mismatch in the window vetoes" $?
lf_observe sessK stale tmux-id-1 ROW6 "$g6" t5
lf_observe sessK stale tmux-id-1 ROW6 "$g6" t6
: > "$ROOT/state/foreign-claude"
lf_kill sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ];   check "standby re-checked AT THE KILL (TOCTOU closed): foreign Claude blocks the action" $?
rm -f "$ROOT/state/foreign-claude"
lf_type sessX hello 2>/dev/null || true
: > "$ROOT/state/foreign-claude"
lf_type sessY hello 2>/dev/null; [ $? -eq 1 ];                  check "typing/prompting is gated by standby exactly like a kill" $?
rm -f "$ROOT/state/foreign-claude"
lf_kill sessK tmux-id-1 ROW6 "$g6";                             check "repeated classified evidence, verified identity + generation: kill proceeds" $?
lf_release ROW6 sessK "$g6" && g6b=$(lf_acquire ROW6 sessK 600)
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6b" 2>/dev/null; [ $? -eq 1 ]
check "old observations cannot be replayed against a NEW lease generation" $?

# ---- N=1 compaction ceiling ------------------------------------------------------------------------
g8=$(lf_acquire ROW7 sessN 60)
lf_compaction sessN
lf_acquire ROW8 sessN 60 >/dev/null 2>&1; [ $? -eq 1 ];         check "after one classified compaction the session acquires NO further row" $?
lf_start_job ROW7 sessN "$g8" JOBN 2>/dev/null; [ $? -eq 1 ];   check "a compacted session starts NO new job (hand off, don't work)" $?
lf_renew ROW7 sessN "$g8" 60;                                   check "a compacted session may renew to reach its boundary safely" $?
lf_commit_boundary ROW7 sessN "$g8";                            check "a compacted session CAN (must) hand off and stop" $?
lf_acquire ROW8 sessFresh 60 >/dev/null;                        check "a fresh session still acquires rows (ceiling is per-session)" $?

# ---- 13: rollback/teardown — explicit, verified, and the repo tree untouched ------------------------
tmux -L "$SOCK" kill-server 2>/dev/null
tmux -L "$SOCK" has-session -t "$TMUX_SESSION" 2>/dev/null; [ $? -ne 0 ]
check "rollback: the private tmux server is gone (no live surrogate)" $?
repo_writes=$(find . -path ./.git -prune -o -newer "$STAMP" -type f -print 2>/dev/null | wc -l)
[ "$repo_writes" -eq 0 ]
check "rollback: ZERO repo-tree files (tracked, ignored, or untracked) were written during the run" $?
TEARDOWN_ROOT="$ROOT"
END_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ---- result manifest (post-run, binding artifacts + results + teardown) ----------------------------
MANIFEST=$(
    echo "artifact proto.sh sha256=$(sha256sum tests/lifecycle/proto.sh | cut -d' ' -f1)"
    echo "artifact lifecycle_falsifier.sh sha256=$(sha256sum tests/lifecycle_falsifier.sh | cut -d' ' -f1)"
    echo "started=$START_TS finished=$END_TS"
    echo "scenarios=${#RESULTS[@]} failures=$fails"
    printf '%s\n' "${RESULTS[@]}"
    echo "teardown=private-tmux-server-killed temp-root-removed-on-exit repo-writes=$repo_writes"
    echo "exit_status=$fails"
)
printf '%s\n' "$MANIFEST"
echo "manifest_sha256=$(printf '%s\n' "$MANIFEST" | sha256sum | cut -d' ' -f1)"
[ -n "${LF_MANIFEST_OUT:-}" ] && printf '%s\n' "$MANIFEST" > "$LF_MANIFEST_OUT"

rm -rf "$TEARDOWN_ROOT"
[ ! -e "$TEARDOWN_ROOT" ] || { echo "FAIL teardown left the temporary root behind"; fails=1; }

if [ "$fails" -ne 0 ]; then echo "FAIL lifecycle_falsifier.sh"; exit 1; fi
echo "PASS lifecycle_falsifier.sh"
