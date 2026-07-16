#!/usr/bin/env bash
# R77 / PLAN-007 earliest falsifiable proof — round-4 revision of the DISPOSABLE lifecycle
# falsifier. Drives tests/lifecycle/proto.sh plus a long-lived interactive surrogate on a
# PRIVATE tmux socket. Nothing touches production paths, credentials, sessions, or `claude -p`.
# Round-4 deltas: authority (CAS + strictly-live lease) replayed by an EXPIRED owner before any
# takeover; halted publishes leave no temp files and never advance the clock floor; the
# recorded successor is content-encoded (dot-safe ids proven); the prompt path is fenced like a
# kill; lf_recover reports dead-letters; every crash injection is PROVEN to fire (rc 97
# asserted); handoff validation is exact (field uniqueness, ledger-recomputed jobs equality,
# regex-escaped ids); ordinary release refuses during a pending rotation; ALL lifecycle roots
# are torn down before the audited manifest, and LF_MANIFEST_OUT must be an absolute path
# outside the repository. Loud-SKIP (77) box contract when tmux is absent.
set -uo pipefail
cd "$(dirname "$0")/.."

command -v tmux  >/dev/null 2>&1 || { echo "SKIP lifecycle_falsifier.sh: tmux absent (box-only falsifier)"; exit 77; }
command -v flock >/dev/null 2>&1 || { echo "SKIP lifecycle_falsifier.sh: flock absent"; exit 77; }

START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fails=0
RESULTS=()
check() {
    if [ "$2" -eq 0 ]; then echo "ok   $1"; RESULTS+=("ok   $1"); else echo "FAIL $1"; RESULTS+=("FAIL $1"); fails=1; fi
}

ROOT=$(mktemp -d)
SOCK="lf-$$"
TMUX_SESSION="lf-falsifier-$$-$RANDOM"
STAMP="$ROOT/repo-stamp"; touch "$STAMP"; sleep 0.05
trap 'tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/fake-home/.claude"
echo 'fake-credential-material' > "$ROOT/fake-home/.claude/.credentials.json"

. tests/lifecycle/proto.sh
lf_init "$ROOT/state" supervisor-token

# ---- surrogate ---------------------------------------------------------------------------------
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
check "surrogate runs long-lived on a PRIVATE tmux socket (own server)" $?
tmux has-session -t "$TMUX_SESSION" 2>/dev/null; [ $? -ne 0 ]
check "the surrogate session is absent from the default tmux server" $?
echo work > "$ROOT/cmds"; sleep 0.6
grep -q child-work-done "$ROOT/events" 2>/dev/null
check "surrogate spawns and completes controlled child work (no claude -p anywhere)" $?

# ---- id sanitization + regex discipline -----------------------------------------------------------
lf_acquire "../evil" sessA 60 >/dev/null 2>&1; [ $? -eq 1 ];   check "row id '../evil' refuses" $?
lf_acquire ROWX "../evil" 60 >/dev/null 2>&1; [ $? -eq 1 ];    check "session id '../evil' refuses" $?
g0=$(lf_acquire ROWX sessA 60)
lf_start_job ROWX sessA "$g0" "../../evil" 2>/dev/null; [ $? -eq 1 ]; check "job id '../../evil' refuses" $?
lf_recover "../evil" >/dev/null 2>&1; [ $? -eq 1 ];            check "read-only recovery sanitizes its row id" $?
lf_observe sessA "stale
class=unknown" id ROWX "$g0" t1 2>/dev/null; [ $? -eq 1 ];     check "a multiline/forged class value refuses" $?
[ ! -e "$ROOT/evil" ] && [ ! -e "$(dirname "$ROOT")/evil" ];   check "no escaped file was created" $?
lf_release ROWX sessA "$g0"
# '.' in ids never wildcards: jobs of row A.B must not match row AxB
gab=$(lf_acquire A.B s1 60); lf_start_job A.B s1 "$gab" JAB
gxb=$(lf_acquire AxB s2 60); lf_start_job AxB s2 "$gxb" JXB
[ "$(lf_jobs_of_lease A.B "$gab")" = "JAB" ];                  check "reverse trace escapes '.' — row A.B never matches row AxB" $?
lf_release A.B s1 "$gab"; lf_release AxB s2 "$gxb"

# ---- race with ready acknowledgements ----------------------------------------------------------------
( : > "$ROOT/readyA"; until [ -e "$ROOT/go" ]; do :; done; lf_acquire ROW1 sessA 60 > "$ROOT/raceA" 2>/dev/null ) &
( : > "$ROOT/readyB"; until [ -e "$ROOT/go" ]; do :; done; lf_acquire ROW1 sessB 60 > "$ROOT/raceB" 2>/dev/null ) &
until [ -e "$ROOT/readyA" ] && [ -e "$ROOT/readyB" ]; do :; done
: > "$ROOT/go"; wait
winners=0 own="" gen=""
[ -s "$ROOT/raceA" ] && { winners=$((winners+1)); own=sessA; gen=$(cat "$ROOT/raceA"); }
[ -s "$ROOT/raceB" ] && { winners=$((winners+1)); own=sessB; gen=$(cat "$ROOT/raceB"); }
[ "$winners" -eq 1 ] && [ "$gen" = "1" ]
check "race (both racers acknowledged ready before release): exactly one wins generation 1" $?
loser=$( [ "$own" = sessA ] && echo sessB || echo sessA )
lf_acquire ROW1 "$own" 60 >/dev/null 2>&1; [ $? -eq 1 ];       check "the LIVE owner cannot re-acquire its own row" $?
lf_start_job ROW1 "$own" "$gen" JOB1;                          check "winner starts exactly one mapped job" $?
lf_start_job ROW1 "$own" "$gen" JOB1 2>/dev/null; [ $? -eq 1 ]; check "duplicate job launch refuses" $?
lf_start_job ROW1 "$loser" "$gen" JOB2 2>/dev/null; [ $? -eq 1 ]; check "loser cannot start a job" $?
grep -q "session=$own" "$ROOT/state/jobs/JOB1";                check "forward trace: job names row, generation, session" $?
[ "$(lf_jobs_of_lease ROW1 "$gen")" = "JOB1" ];                check "reverse trace: the lease lists exactly its authorized jobs" $?

# ---- authority dies WITH the lease: expired owner, no takeover yet ------------------------------------
ge=$(lf_acquire ROWE sessE 1); sleep 2
exp_fails=0
for op in "lf_renew ROWE sessE $ge 60" "lf_start_job ROWE sessE $ge JOBE" \
          "lf_release ROWE sessE $ge" "lf_commit_boundary ROWE sessE $ge" \
          "lf_soft_trip ROWE sessE $ge" "lf_activity ROWE sessE $ge" \
          "lf_safety_flag ROWE sessE $ge" "lf_type sessE ROWE $ge hello"; do
    $op >/dev/null 2>&1; [ $? -eq 1 ] || { echo "FAIL expired owner kept authority: $op"; exp_fails=1; }
done
check "an EXPIRED owner loses every authority operation BEFORE any takeover" $exp_fails
sed -i 's/^expiry=.*/expiry=bogus/' "$ROOT/state/rows/ROWE.lease"
lf_start_job ROWE sessE "$ge" JOBE2 2>/dev/null; [ $? -eq 1 ]
check "a malformed EXPIRY grants no authority to its own owner" $?
sed -i "s/^expiry=.*/expiry=$(( $(date +%s) + 60 ))/; s/^generation=.*/generation=bogus/" "$ROOT/state/rows/ROWE.lease"
lf_start_job ROWE sessE bogus JOBE3 2>/dev/null; [ $? -eq 1 ]
check "a live lease with a NON-NUMERIC generation grants nothing (whole-schema authority)" $?
sed -i "s/^generation=.*/generation=$ge/; s/^row=.*/row=OTHER/" "$ROOT/state/rows/ROWE.lease"
lf_start_job ROWE sessE "$ge" JOBE4 2>/dev/null; [ $? -eq 1 ]
check "a lease whose row field disagrees with its filename grants nothing" $?
sed -i "s/^row=.*/row=ROWE/; s/^expiry=.*/expiry=0/" "$ROOT/state/rows/ROWE.lease"

# ---- soft trip ------------------------------------------------------------------------------------------
lf_soft_trip ROW1 "$loser" "$gen" 2>/dev/null; [ $? -eq 1 ];   check "a non-owner cannot request rotation" $?
lf_soft_trip ROW1 "$own" "$gen";                               check "the owner requests rotation at a soft threshold" $?
lf_renew ROW1 "$own" "$gen" 60;                                check "soft trip: current task continues (renew ok)" $?
lf_start_job ROW1 "$own" "$gen" JOB-NEW 2>/dev/null; [ $? -eq 1 ]; check "soft trip: NEW job refused until the boundary" $?
lf_acquire ROW1 sessC 60 >/dev/null 2>&1; [ $? -eq 1 ];        check "soft trip: NEW acquisition refused" $?
lf_release ROW1 "$own" "$gen" 2>/dev/null; [ $? -eq 1 ]
check "ordinary release refuses during a pending rotation (the boundary is the only exit)" $?

# ---- safe boundary ---------------------------------------------------------------------------------------
lf_commit_boundary ROW1 "$own" "$gen";                         check "boundary: handoff + release + marker cleanup in one transaction" $?
[ ! -e "$ROOT/state/rows/ROW1.rotate" ];                       check "the fulfilled rotation request is gone" $?
lf_acquire ROW1 sessE2 60 >/dev/null 2>&1; [ $? -eq 1 ];       check "an unconsumed handoff fences bare acquisition" $?
grep -q '^source=ledger$' "$ROOT/state/handoffs/ROW1.gen$gen"; check "handoff declares its ledger derivation" $?
grep -q "jobs=JOB1" "$ROOT/state/handoffs/ROW1.gen$gen";       check "handoff carries the recomputed job map" $?
echo stop > "$ROOT/cmds"; sleep 0.4
grep -q stopped "$ROOT/events";                                check "owner session self-stops at the boundary" $?

# ---- successor (dot-safe id) --------------------------------------------------------------------------------
g2=$(lf_consume_handoff ROW1 succ.v2);                         check "successor consumes handoff + lease in ONE transaction" $?
[ "$g2" -gt "$gen" ];                                          check "generation is monotonic across rotation" $?
grep -q '^successor=succ.v2$' "$ROOT/state/consumed/ROW1.gen$gen"
check "the successor is recorded IN CONTENT — a dotted session id survives exactly" $?
lf_consume_handoff ROW1 sessD 2>/dev/null; [ $? -eq 1 ];       check "second consumption refuses" $?
lf_start_job ROW1 succ.v2 "$g2" JOB1 2>/dev/null; [ $? -eq 1 ]; check "successor cannot duplicate the predecessor's job id" $?
# handoff validation: exactness sweep
g_pre=$(lf_acquire ROWP sessP 60); lf_start_job ROWP sessP "$g_pre" JOBP
lf_consume_handoff ROWP sessQ 2>/dev/null; [ $? -eq 1 ];       check "consumption refuses while the from-lease is LIVE" $?
lf_commit_boundary ROWP sessP "$g_pre"
H="$ROOT/state/handoffs/ROWP.gen$g_pre"
cp "$H" "$ROOT/h.bak"
sed -i 's/^row=.*/row=ROWZ/' "$H"
lf_consume_handoff ROWP sessQ 2>/dev/null; [ $? -eq 1 ];       check "wrong row refuses" $?
cp "$ROOT/h.bak" "$H"; sed -i 's/^from_generation=.*/from_generation=999/' "$H"
lf_consume_handoff ROWP sessQ 2>/dev/null; [ $? -eq 1 ];       check "wrong generation refuses" $?
cp "$ROOT/h.bak" "$H"; sed -i '/^from_session=/d' "$H"
lf_consume_handoff ROWP sessQ 2>/dev/null; [ $? -eq 1 ];       check "a missing predecessor field refuses" $?
cp "$ROOT/h.bak" "$H"; printf 'row=OTHER\n' >> "$H"
lf_consume_handoff ROWP sessQ 2>/dev/null; [ $? -eq 1 ];       check "duplicate contradictory fields refuse (uniqueness)" $?
cp "$ROOT/h.bak" "$H"; sed -i 's/^jobs=.*/jobs=FORGED/' "$H"
lf_consume_handoff ROWP sessQ 2>/dev/null; [ $? -eq 1 ];       check "a jobs field that differs from the LEDGER's recomputed trace refuses" $?
cp "$ROOT/h.bak" "$H"; sed -i 's/^from_session=.*/from_session=sessForged/' "$H"
lf_consume_handoff ROWP sessQ 2>/dev/null; [ $? -eq 1 ]
check "a valid-looking but FOREIGN predecessor refuses (checked against the job ledger)" $?
cp "$ROOT/h.bak" "$H"; printf 'successor=evil\n' >> "$H"
lf_consume_handoff ROWP sessQ 2>/dev/null; [ $? -eq 1 ]
check "an unknown/injected field refuses (closed-world handoff schema)" $?
cp "$ROOT/h.bak" "$H"
# NO-JOBS handoff: the predecessor is still ledger-verified via the released lease's
# last_session field — a forged-but-valid from_session refuses even with zero jobs
gnj=$(lf_acquire ROWNJ sessNJ 600)
lf_commit_boundary ROWNJ sessNJ "$gnj"
sed -i 's/^from_session=.*/from_session=sessForged/' "$ROOT/state/handoffs/ROWNJ.gen$gnj"
lf_consume_handoff ROWNJ sessQ2 2>/dev/null; [ $? -eq 1 ]
check "a forged predecessor refuses on a NO-JOBS handoff too (last_session provenance)" $?
sed -i 's/^from_session=.*/from_session=sessNJ/' "$ROOT/state/handoffs/ROWNJ.gen$gnj"
lf_consume_handoff ROWNJ sessQ2 >/dev/null
check "the honest no-jobs handoff consumes cleanly" $?
cp "$H" "$ROOT/state/handoffs/ROWP.gen999"
lf_consume_handoff ROWP sessQ 2>/dev/null; [ $? -eq 1 ];       check "TWO handoffs for one row refuse" $?
rm "$ROOT/state/handoffs/ROWP.gen999"
lf_consume_handoff ROWP sessQ >/dev/null;                      check "the intact single handoff consumes cleanly" $?

# ---- expiry + clock ------------------------------------------------------------------------------------------
g3=$(lf_acquire ROW2 sessOld 1); sleep 2
g4=$(lf_acquire ROW2 sessNew 60);                              check "expired lease: fresh session acquires the next generation" $?
[ "$g4" -gt "$g3" ];                                           check "takeover raises the generation" $?
stale_fails=0
for op in "lf_renew ROW2 sessOld $g3 60" "lf_release ROW2 sessOld $g3" \
          "lf_start_job ROW2 sessOld $g3 JOBX" "lf_commit_boundary ROW2 sessOld $g3" \
          "lf_soft_trip ROW2 sessOld $g3" "lf_activity ROW2 sessOld $g3" \
          "lf_safety_flag ROW2 sessOld $g3" "lf_type sessOld ROW2 $g3 hello"; do
    $op >/dev/null 2>&1; [ $? -eq 1 ] || { echo "FAIL stale session not refused: $op"; stale_fails=1; }
done
check "a SUPERSEDED session is refused at every fenced operation (incl. prompting)" $stale_fails
sed -i 's/^expiry=.*/expiry=not-a-number/' "$ROOT/state/rows/ROW2.lease"
lf_acquire ROW2 sessEvil 60 >/dev/null 2>&1; [ $? -eq 1 ];     check "malformed expiry fences takeover" $?
sed -i "s/^expiry=.*/expiry=$(( $(date +%s) + 60 ))/" "$ROOT/state/rows/ROW2.lease"
echo $(( $(date +%s) + 99999 )) > "$ROOT/state/.last_now"
lf_acquire ROW-CLK sessA 60 >/dev/null 2>&1; [ $? -eq 1 ];     check "backward clock: acquire refuses" $?
lf_renew ROW2 sessNew "$g4" 60 2>/dev/null; [ $? -eq 1 ];      check "backward clock: renew refuses" $?
floor_before=$(cat "$ROOT/state/.last_now")
lf_recover ROW2 >/dev/null
[ "$(cat "$ROOT/state/.last_now")" = "$floor_before" ];        check "read-only recovery never mutates the clock floor" $?
echo 0 > "$ROOT/state/.last_now"
chmod 000 "$ROOT/state/.last_now"
lf_acquire ROW-CLK sessA 60 >/dev/null 2>&1; [ $? -eq 1 ]
check "an UNREADABLE clock floor refuses acquisition (unreadable is corruption, never zero)" $?
chmod 644 "$ROOT/state/.last_now"
mv "$ROOT/state/.last_now" "$ROOT/state/.last_now.away"
lf_acquire ROW-CLK sessA 60 >/dev/null 2>&1; [ $? -eq 1 ]
check "a MISSING clock floor refuses too (init always creates it — absence is corruption)" $?
mv "$ROOT/state/.last_now.away" "$ROOT/state/.last_now"

# ---- HALT: entry sweep + commit instant (no temp residue, no floor advance) --------------------------------
: > "$ROOT/state/HALT"
halt_fails=0
for op in "lf_acquire ROW3 sessH 60" "lf_renew ROW2 sessNew $g4 60" "lf_release ROW2 sessNew $g4" \
          "lf_start_job ROW2 sessNew $g4 JOBH" "lf_soft_trip ROW2 sessNew $g4" \
          "lf_compaction sessNew" "lf_commit_boundary ROW2 sessNew $g4" \
          "lf_consume_handoff ROW2 sessH" "lf_respawn ROW2 supervisor-token" \
          "lf_activity ROW2 sessNew $g4" "lf_safety_flag ROW2 sessNew $g4" \
          "lf_observe sessNew stale id ROW2 $g4 t1" "lf_kill_eligible sessNew id ROW2 $g4" \
          "lf_kill sessNew id ROW2 $g4" "lf_type sessNew ROW2 $g4 hello" "lf_recover_finish ROW2"; do
    $op >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 9 ] || { echo "FAIL HALT did not stop: $op (rc=$rc)"; halt_fails=1; }
done
check "HALT entry sweep refuses every mutator (rc 9)" $halt_fails
rm -f "$ROOT/state/HALT"
before=$(cat "$ROOT/state/rows/ROW2.lease")
floor_before=$(cat "$ROOT/state/.last_now")
LF_HALT_AT=commit lf_renew ROW2 sessNew "$g4" 60 2>/dev/null; rc=$?
tmps=$(find "$ROOT/state" -name '.tmp.*' | wc -l)
[ "$rc" -eq 9 ] && [ "$(cat "$ROOT/state/rows/ROW2.lease")" = "$before" ] \
  && [ "$tmps" -eq 0 ] && [ "$(cat "$ROOT/state/.last_now")" = "$floor_before" ]
check "HALT at the COMMIT INSTANT: publish stopped, staged temp removed, clock floor untouched" $?
rm -f "$ROOT/state/HALT"
lf_respawn ROW2 supervisor-token >/dev/null
LF_HALT_AT=commit lf_activity ROW2 sessNew "$g4" 2>/dev/null; rc=$?
[ "$rc" -eq 9 ] && [ -e "$ROOT/state/respawns/ROW2" ]
check "raw transitions (marker/counter removal) honor the commit gate" $?
rm -f "$ROOT/state/HALT"
lf_activity ROW2 sessNew "$g4"
# floor-specific HALT window: the primary record publishes, the floor update is SKIPPED whole
floor_before=$(cat "$ROOT/state/.last_now")
exp_before=$(sed -n 's/^expiry=//p' "$ROOT/state/rows/ROW2.lease")
LF_HALT_AT=floor lf_renew ROW2 sessNew "$g4" 120; rc=$?
tmps=$(find "$ROOT/state" -maxdepth 1 -name '.tmp.*' | wc -l)
[ "$rc" -eq 0 ] && [ "$(sed -n 's/^expiry=//p' "$ROOT/state/rows/ROW2.lease")" != "$exp_before" ] \
  && [ "$(cat "$ROOT/state/.last_now")" = "$floor_before" ] && [ "$tmps" -eq 0 ]
check "HALT in the floor-publish window: primary record landed, floor skipped whole, no temp" $?
rm -f "$ROOT/state/HALT"
# ordinary I/O failure aborts the transaction BEFORE dependent writes (no errexit reliance)
gio=$(lf_acquire ROWIO sessIO 600); lf_start_job ROWIO sessIO "$gio" JOBIO >/dev/null
chmod 555 "$ROOT/state/handoffs"
lf_commit_boundary ROWIO sessIO "$gio" 2>/dev/null; rc=$?
chmod 755 "$ROOT/state/handoffs"
[ "$rc" -ne 0 ] && [ "$(sed -n 's/^session=//p' "$ROOT/state/rows/ROWIO.lease")" = "sessIO" ] \
  && [ ! -e "$ROOT/state/handoffs/ROWIO.gen$gio" ]
check "a failed handoff publish ABORTS the boundary — the lease is NOT released (no stranding)" $?
# an UNREADABLE job ledger aborts the boundary — never a trusted-empty handoff
chmod 000 "$ROOT/state/jobs/JOBIO"
lf_commit_boundary ROWIO sessIO "$gio" 2>/dev/null; rc=$?
chmod 644 "$ROOT/state/jobs/JOBIO"
[ "$rc" -ne 0 ] && [ "$(sed -n 's/^session=//p' "$ROOT/state/rows/ROWIO.lease")" = "sessIO" ] \
  && [ ! -e "$ROOT/state/handoffs/ROWIO.gen$gio" ]
check "an UNREADABLE job ledger ABORTS the boundary (never a trusted-empty job map)" $?
lf_commit_boundary ROWIO sessIO "$gio" >/dev/null
chmod 000 "$ROOT/state/handoffs/ROWIO.gen$gio"
lf_consume_handoff ROWIO sessIO2 2>/dev/null; rc=$?
chmod 644 "$ROOT/state/handoffs/ROWIO.gen$gio"
[ "$rc" -ne 0 ] && [ ! -e "$ROOT/state/consumed/ROWIO.gen$gio" ] \
  && [ -e "$ROOT/state/handoffs/ROWIO.gen$gio" ]
check "an UNREADABLE handoff ABORTS consumption — no partial successor-only record" $?
lf_consume_handoff ROWIO sessIO2 >/dev/null

# ---- crash matrix: point-specific oracles AND proven injections ---------------------------------------------
crash_fails=0
crash_case() {  # $1 point, $2 expected-recovery
    local point=$1 expect=$2
    local CR="$ROOT/crash-$point"
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
            before-consume|after-consume-record|after-handoff-retire|after-successor-lease)
                g=$(lf_acquire CROW s1 60); lf_commit_boundary CROW s1 "$g"
                LF_CRASH_POINT=$point lf_consume_handoff CROW s2 ;;
        esac
    ) >/dev/null 2>&1
    local sub_rc=$?
    local out rc=0
    out=$(LF_ROOT="$CR" lf_recover CROW)
    [ "$out" = "$expect" ] || rc=1
    [ "$sub_rc" -eq 97 ] || rc=1     # the injection MUST actually have fired
    local stray; stray=$(find "$CR" -name '.tmp.*' | wc -l)
    { [ "$rc" -eq 0 ] && [ "$stray" -eq 0 ]; } || { echo "FAIL crash@$point: rc=$sub_rc recover='$out' want='$expect' stray=$stray"; crash_fails=1; }
}
crash_case before-lease-write     "released"
crash_case after-lease-write      "owner s1"
crash_case before-job-write       "owner s1"
crash_case after-job-write        "owner s1"
crash_case before-release         "owner s1"
crash_case after-release          "released"
crash_case before-handoff-write   "owner s1"
crash_case after-handoff-write    "owner s1"
crash_case after-boundary-release "handoff-ready"
crash_case before-consume         "handoff-ready"
crash_case after-consume-record   "consumed-by s2"
crash_case after-handoff-retire   "consumed-by s2"
crash_case after-successor-lease  "owner s2"
check "crash matrix (13 points): every injection PROVEN fired (rc 97) and every recovery exact" $crash_fails
[ ! -e "$ROOT/crash-before-job-write/jobs/CJOB" ] && [ -e "$ROOT/crash-after-job-write/jobs/CJOB" ]
check "job record exists after its publish point and not before" $?
CR="$ROOT/crash-after-consume-record"
LF_ROOT="$CR" lf_acquire CROW s3 60 >/dev/null 2>&1; [ $? -eq 1 ]
check "interrupted consumption fences bare acquisition" $?
LF_ROOT="$CR" lf_consume_handoff CROW s3 >/dev/null 2>&1; [ $? -eq 1 ]
[ "$(sed -n 's/^successor=//p' "$CR/consumed/CROW.gen1")" = "s2" ]
check "a SECOND consumer cannot overwrite the recorded successor (duplicate consumption refused)" $?
# N=1 holds through recovery: a successor compacted after the interrupted consumption gets
# no lease — probe on a COPY of the fixture so the real recovery below still runs
CRN="$ROOT/crash-n1"; cp -r "$CR" "$CRN"
( . tests/lifecycle/proto.sh; LF_ROOT="$CRN"; : > "$CRN/compacted.s2"
  lf_recover_finish CROW ) >/dev/null 2>&1; [ $? -eq 1 ]
check "recovery refuses to mint a COMPACTED successor (N=1 survives the crash path)" $?
fin=$(LF_ROOT="$CR" lf_recover_finish CROW)
[ "$fin" = "s2" ] && [ "$(LF_ROOT="$CR" lf_recover CROW)" = "owner s2" ] \
  && [ ! -e "$CR/handoffs/CROW.gen1" ]
check "recovery retires the leftover handoff and mints exactly the RECORDED successor" $?
CR="$ROOT/crash-after-handoff-write"
LF_ROOT="$CR" lf_consume_handoff CROW s3 >/dev/null 2>&1; [ $? -eq 1 ]
check "a handoff beside a live lease is unconsumable (no dual authority)" $?
CR="$ROOT/crash-mkr"; mkdir -p "$CR"
( . tests/lifecycle/proto.sh; lf_init "$CR" sup
  g=$(lf_acquire CROW s1 600); lf_soft_trip CROW s1 "$g"
  LF_CRASH_POINT=after-boundary-release lf_commit_boundary CROW s1 "$g" ) >/dev/null 2>&1
g9=$(LF_ROOT="$CR" lf_consume_handoff CROW s2)
LF_ROOT="$CR" lf_start_job CROW s2 "$g9" CJOB2 >/dev/null
check "a marker stranded by a boundary crash is cleared by consumption" $?

# ---- doom loop ------------------------------------------------------------------------------------------------
lf_respawn ROW4 wrong-token 2>/dev/null; [ $? -eq 1 ];         check "respawn counting requires the supervisor token" $?
lf_respawn ROW4 supervisor-token; lf_respawn ROW4 supervisor-token
g7=$(lf_acquire ROW4 sessR 60)
lf_activity ROW4 sessR "$g7"
lf_respawn ROW4 supervisor-token; lf_respawn ROW4 supervisor-token
lf_respawn ROW4 supervisor-token; [ $? -eq 3 ];                check "third consecutive activity-free respawn dead-letters" $?
lf_respawn ROW4 supervisor-token 2>/dev/null; [ $? -eq 3 ];    check "no fourth automatic respawn" $?
dl_fails=0
for op in "lf_acquire ROW4 sessZ 60" "lf_renew ROW4 sessR $g7 60" "lf_release ROW4 sessR $g7" \
          "lf_start_job ROW4 sessR $g7 JOBD" "lf_commit_boundary ROW4 sessR $g7" \
          "lf_soft_trip ROW4 sessR $g7" "lf_activity ROW4 sessR $g7" "lf_consume_handoff ROW4 sessZ" \
          "lf_safety_flag ROW4 sessR $g7" "lf_observe sessR stale id ROW4 $g7 t9" \
          "lf_type sessR ROW4 $g7 hello" "lf_recover_finish ROW4"; do
    $op >/dev/null 2>&1; [ $? -eq 3 ] || { echo "FAIL dead-letter did not fence: $op"; dl_fails=1; }
done
check "a dead-letter fences EVERY row operation (incl. prompting, re-flag, observe, recover-finish)" $dl_fails
[ "$(lf_recover ROW4)" = "dead-lettered" ]
check "read-only recovery reports the dead-letter — it never names a promptable owner" $?
lf_kill sessR id ROW4 "$g7" 2>/dev/null; [ $? -eq 1 ];         check "a dead-lettered row's session cannot be killed on stale authority" $?

# ---- safety flag ------------------------------------------------------------------------------------------------
g5=$(lf_acquire ROW5 sessS 60)
lf_safety_flag ROW5 sessS "$((g5 + 7))" 2>/dev/null; [ $? -eq 1 ]; check "safety flag with a wrong generation refuses" $?
lf_safety_flag ROW5 sessOther "$g5" 2>/dev/null; [ $? -eq 1 ];  check "safety flag from a non-owner refuses" $?
lf_safety_flag ROW5 sessS "$g5";                                check "safety-flagged turn dead-letters immediately" $?
lf_start_job ROW5 sessS "$g5" JOBS 2>/dev/null; [ $? -eq 3 ];   check "no further row action after a safety dead-letter" $?
[ ! -e "$ROOT/state/deadletters/ROW6" ];                        check "the safety flag cannot touch a different row" $?

# ---- kill + prompt discipline --------------------------------------------------------------------------------------
g6=$(lf_acquire ROW6 sessK 600)
lf_observe sessK stale tmux-id-1 ROW6 "$g6" t1
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]; check "ONE stale observation cannot kill" $?
lf_observe sessK stale tmux-id-1 ROW6 "$g6" t1
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]; check "two observations sharing a tick label cannot kill" $?
lf_observe sessK unknown tmux-id-1 ROW6 "$g6" aaa
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]
check "an 'unknown' vetoes by ARRIVAL ORDER even with a lexically earlier tick label" $?
lf_observe sessK stale tmux-id-1 ROW6 "$g6" t3
lf_observe sessK stale tmux-id-OTHER ROW6 "$g6" t4
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ]; check "an identity mismatch in the last-two window vetoes" $?
lf_observe sessK stale tmux-id-1 ROW6 "$g6" t5
lf_observe sessK stale tmux-id-1 ROW6 "$g6" t6
: > "$ROOT/state/foreign-claude"
lf_kill sessK tmux-id-1 ROW6 "$g6" 2>/dev/null; [ $? -eq 1 ];   check "standby re-checked AT THE KILL (TOCTOU closed)" $?
lf_type sessK ROW6 "$g6" hello 2>/dev/null; [ $? -eq 1 ];       check "prompting is gated by standby exactly like a kill" $?
rm -f "$ROOT/state/foreign-claude"
lf_type sessK ROW6 "$g6" hello;                                 check "the live authority holder CAN be prompted (row+generation bound)" $?
lf_type sessK ROW6 "$((g6 + 5))" hello 2>/dev/null; [ $? -eq 1 ]; check "a prompt with a wrong generation refuses" $?
lf_kill sessK tmux-id-1 ROW6 "$g6";                             check "repeated classified evidence, verified identity + generation: kill proceeds" $?
lf_release ROW6 sessK "$g6" && g6b=$(lf_acquire ROW6 sessK 600)
lf_kill_eligible sessK tmux-id-1 ROW6 "$g6b" 2>/dev/null; [ $? -eq 1 ]
check "old observations cannot be replayed against a NEW lease generation" $?
# a forged/malformed lease can never authorize a kill, and recovery never names its owner
gm=$(lf_acquire ROWM sessM 600)
lf_observe sessM stale id-m ROWM "$gm" m1
lf_observe sessM stale id-m ROWM "$gm" m2
sed -i 's/^row=.*/row=FORGED/' "$ROOT/state/rows/ROWM.lease"
lf_kill sessM id-m ROWM "$gm" 2>/dev/null; [ $? -eq 1 ]
check "a lease with a FORGED row field cannot authorize a kill (whole-schema authority)" $?
[ "$(lf_recover ROWM)" = "invalid-lease" ]
check "recovery reports invalid-lease for a forged record — never a promptable owner" $?
sed -i 's/^row=.*/row=ROWM/' "$ROOT/state/rows/ROWM.lease"
lf_release ROWM sessM "$gm"

# ---- N=1 --------------------------------------------------------------------------------------------------------------
g8=$(lf_acquire ROW7 sessN 60)
lf_compaction sessN
lf_acquire ROW8 sessN 60 >/dev/null 2>&1; [ $? -eq 1 ];         check "after one classified compaction: no further row acquisition" $?
lf_start_job ROW7 sessN "$g8" JOBN 2>/dev/null; [ $? -eq 1 ];   check "a compacted session starts NO new job" $?
lf_renew ROW7 sessN "$g8" 60;                                   check "a compacted session may renew to reach its boundary" $?
lf_commit_boundary ROW7 sessN "$g8";                            check "a compacted session CAN (must) hand off and stop" $?
lf_consume_handoff ROW7 sessN >/dev/null 2>&1; [ $? -eq 1 ];    check "a compacted session cannot re-enter through consumption" $?
lf_consume_handoff ROW7 sessFresh >/dev/null;                   check "a fresh session consumes the handoff normally" $?

# ---- COMPLETE teardown, THEN the audited manifest ----------------------------------------------------------------------
tmux -L "$SOCK" kill-server 2>/dev/null
tmux -L "$SOCK" has-session -t "$TMUX_SESSION" 2>/dev/null; [ $? -ne 0 ]
check "teardown: the private tmux server is gone" $?
rm -rf "$ROOT/state" "$ROOT/fake-home" "$ROOT"/crash-* 2>/dev/null
leftover=$(find "$ROOT" -maxdepth 1 \( -name 'state' -o -name 'fake-home' -o -name 'crash-*' \) | wc -l)
[ "$leftover" -eq 0 ]
check "teardown: ALL lifecycle roots (state + every crash fixture + fake credentials) removed" $?
repo_writes=$(find . -path ./.git -prune -o -newer "$STAMP" -type f -print 2>/dev/null | wc -l)
[ "$repo_writes" -eq 0 ]
check "audit: ZERO repo-tree files written during the run" $?
# the evidence copy must NORMALIZE (symlinks, dot-dot) to an absolute path OUTSIDE the repo
manifest_out_ok() {  # $1 candidate path -> rc 0 iff safe
    local norm repo
    norm=$(realpath -m -- "$1" 2>/dev/null) || return 1
    repo=$(realpath -- "$PWD") || return 1
    case "$norm" in
        "$repo"|"$repo"/*) return 1 ;;
        /*) return 0 ;;
        *) return 1 ;;
    esac
}
manifest_out_ok "$PWD/../$(basename "$PWD")/probe" 2>/dev/null; [ $? -ne 0 ]
check "a dot-dot path that RESOLVES inside the repository is rejected (normalized check)" $?
MANIFEST_OUT_OK=1
if [ -n "${LF_MANIFEST_OUT:-}" ]; then
    manifest_out_ok "$LF_MANIFEST_OUT" || MANIFEST_OUT_OK=0
fi
[ "$MANIFEST_OUT_OK" -eq 1 ]
check "LF_MANIFEST_OUT normalizes to an absolute path outside the repository (or is unset)" $?
END_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

MANIFEST=$(
    echo "artifact proto.sh sha256=$(sha256sum tests/lifecycle/proto.sh | cut -d' ' -f1)"
    echo "artifact lifecycle_falsifier.sh sha256=$(sha256sum tests/lifecycle_falsifier.sh | cut -d' ' -f1)"
    echo "started=$START_TS finished=$END_TS"
    echo "scenarios=${#RESULTS[@]} failures=$fails"
    printf '%s\n' "${RESULTS[@]}"
    echo "teardown=tmux-server-killed all-roots-removed repo-writes=$repo_writes"
    echo "exit_status=$fails"
)
printf '%s\n' "$MANIFEST"
echo "manifest_sha256=$(printf '%s\n' "$MANIFEST" | sha256sum | cut -d' ' -f1)"
if [ -n "${LF_MANIFEST_OUT:-}" ] && [ "$MANIFEST_OUT_OK" -eq 1 ]; then
    printf '%s\n' "$MANIFEST" > "$LF_MANIFEST_OUT" \
        || { echo "FAIL manifest evidence copy could not be written"; fails=1; }
fi

if [ "$fails" -ne 0 ]; then echo "FAIL lifecycle_falsifier.sh"; exit 1; fi
echo "PASS lifecycle_falsifier.sh"
