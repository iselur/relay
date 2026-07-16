#!/usr/bin/env bash
# THROWAWAY lifecycle prototype (R77 / PLAN-007, earliest falsifiable proof) — round-4 revision.
# Disposable design under test; operates ONLY under a caller-owned temporary root (LF_ROOT);
# touches no production state; nothing outside tests/ may source it.
#
# Design rules (each falsifier-enforced):
# - AUTHORITY = CAS + LIVE: every owner operation requires (session, generation) to match AND
#   the lease to be strictly live (numeric expiry in the future on a readable, monotonic
#   clock). An expired, malformed, or clock-broken lease grants NOTHING to anyone: the old
#   owner loses authority the instant expiry passes, and takeover is the only path forward.
# - IDENTIFIERS: [A-Za-z0-9._-]+ everywhere, public read APIs included; ids are regex-escaped
#   before any grep (a '.' in an id never wildcards).
# - LOCKING: one flock ($LF_ROOT/.lock) serializes every mutation.
# - HALT: checked at entry AND at the COMMIT INSTANT of every durable publish — including the
#   clock floor, which publishes only AFTER the primary record (skipping it on HALT is safe:
#   the floor is a lower bound). A staged temp file is removed when HALT stops the publish.
#   LF_HALT_AT=commit is the test hook that raises HALT after staging.
# - CLOCK: mutators read a validated monotonic 'now' (fail closed on unreadable/backward) and
#   bump the floor only after their record publishes; read paths never mutate the floor.
# - DURABILITY: stage + atomic publish (mv/ln) = atomic VISIBILITY. Crash-durability across
#   host power loss is explicitly out of the prototype's scope.
# - DEAD-LETTER: fences EVERY row operation — mutations, observations, kills, prompts,
#   recovery — and lf_recover reports it instead of naming an owner.
# - HANDOFF: exactly ONE per row; consumption verifies row, from_generation == current
#   generation, a well-formed single predecessor, field uniqueness, AND that the jobs field
#   equals the ledger's recomputed reverse trace; refuses while the from-lease is live; refuses
#   a compacted successor (N=1); the successor is recorded IN CONTENT (dot-safe) durably before
#   the handoff is retired and the lease minted; an interrupted consumption fences bare
#   acquisition and recovery mints exactly the recorded successor.
# - ROTATION: a pending rotate marker forbids ordinary release — the boundary handoff is the
#   only exit, so a row can never be stranded released-but-unacquirable.
# - OBSERVATIONS: server-assigned sequence order; enum-validated class; single-token fields.
# - CRASH INJECTION: LF_CRASH_POINT=<name> exits 97 at the named point (the falsifier asserts
#   the 97, proving each injection actually fired).
# Return codes: 0 ok; 1 refused; 3 dead-lettered; 9 HALT.

set -u

lf_init() {  # $1 root, $2 supervisor-token
    LF_ROOT="$1"
    mkdir -p "$LF_ROOT"/{rows,jobs,handoffs,consumed,deadletters,observations,respawns,killed}
    : > "$LF_ROOT/.lock"
    printf '%s' "${2:-supervisor}" > "$LF_ROOT/supervisor"
    printf '0' > "$LF_ROOT/.obs_seq"
    printf '0' > "$LF_ROOT/.last_now"   # the floor ALWAYS exists post-init: a missing or
    # unreadable floor is corrupt state and fails closed, never "zero"
}

_lf_id() {
    local a
    for a in "$@"; do
        case "$a" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    done
}

_lf_re() {  # regex-escape an id ('.' is the only metachar the id alphabet admits)
    printf '%s' "$1" | sed 's/\./\\./g'
}

_lf_crash() { [ "${LF_CRASH_POINT:-}" = "$1" ] && exit 97; return 0; }
_lf_halt()  { [ -e "$LF_ROOT/HALT" ] && return 9; return 0; }
_lf_dead()  { [ -e "$LF_ROOT/deadletters/$1" ] && return 3; return 0; }

_lf_now_ro() {  # validated monotonic 'now'; NEVER mutates the floor; fails closed on a
    local now last  # missing, UNREADABLE, malformed, or backward floor (init always creates
    now=$(date +%s 2>/dev/null) || return 1   # the floor — absence is corruption, never zero)
    [[ "$now" =~ ^[0-9]+$ ]] || return 1
    last=$(cat "$LF_ROOT/.last_now" 2>/dev/null) || return 1
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    [ "$now" -lt "$last" ] && return 1
    echo "$now"
}

_lf_bump_floor() {  # publish the floor AFTER the primary record, through the SAME commit-gated
    local tmp       # stage+publish shape; on HALT the floor update is SKIPPED (safe: it is a
    tmp="$(mktemp "$LF_ROOT/.tmp.XXXXXX")" || exit 1   # lower bound), never half-published.
    printf '%s' "$1" > "$tmp" || { rm -f "$tmp"; exit 1; }
    [ "${LF_HALT_AT:-}" = "floor" ] && : > "$LF_ROOT/HALT"
    if [ -e "$LF_ROOT/HALT" ]; then rm -f "$tmp" || exit 1; return 0; fi
    mv "$tmp" "$LF_ROOT/.last_now" || { rm -f "$tmp"; exit 1; }
}

_lf_commit_gate() {  # $1 staged-tmp (removed if HALT stops the publish; a temp that survives
    if [ "${LF_HALT_AT:-}" = "commit" ]; then : > "$LF_ROOT/HALT"; fi   # removal is REPORTED)
    if [ -e "$LF_ROOT/HALT" ]; then
        rm -f -- "${1:-}" 2>/dev/null
        [ -n "${1:-}" ] && [ -e "$1" ] && echo "lf: WARNING staged temp survived HALT cleanup: $1" >&2
        exit 9
    fi
}

_lf_write() {  # $1 path, stdin content — ANY I/O failure aborts the whole locked transaction
    _lf_halt || exit 9
    local tmp
    tmp="$(mktemp "$(dirname "$1")/.tmp.XXXXXX")" || exit 1
    cat > "$tmp" || { rm -f "$tmp"; exit 1; }
    _lf_commit_gate "$tmp"
    mv "$tmp" "$1" || { rm -f "$tmp"; exit 1; }
}

_lf_create() {  # exactly-once publish; I/O failure aborts, existing target returns 1
    _lf_halt || exit 9
    local tmp
    tmp="$(mktemp "$(dirname "$1")/.tmp.XXXXXX")" || exit 1
    cat > "$tmp" || { rm -f "$tmp"; exit 1; }
    _lf_commit_gate "$tmp"
    if ln "$tmp" "$1" 2>/dev/null; then rm -f "$tmp" || exit 1; return 0; fi
    rm -f "$tmp" || exit 1
    return 1
}

_lf_remove() {  # gated removal; failure aborts the transaction
    _lf_commit_gate ""
    rm -f "$1" || exit 1
}

_lf_lease_field() {
    [ -f "$LF_ROOT/rows/$1.lease" ] || return 0
    sed -n "s/^$2=//p" "$LF_ROOT/rows/$1.lease"
}

_lf_cas() {
    [ "$(_lf_lease_field "$1" session)" = "$2" ] && [ "$(_lf_lease_field "$1" generation)" = "$3" ]
}

_lf_lease_live() {  # FENCING liveness: malformed expiry or unreadable clock counts as live
    local sess exp now
    sess=$(_lf_lease_field "$1" session)
    [ -n "$sess" ] || return 1
    exp=$(_lf_lease_field "$1" expiry)
    [[ "$exp" =~ ^[0-9]+$ ]] || return 0
    now=$(_lf_now_ro) || return 0
    [ "$exp" -gt "$now" ]
}

_lf_auth() {  # AUTHORITY: CAS + STRICTLY live + WHOLE-SCHEMA-valid lease. The caller's
    local row=$1 session=$2 gen=$3 exp now   # generation argument must be numeric; the lease's
    [[ "$gen" =~ ^[0-9]+$ ]] || return 1     # own row/generation/session fields must be sane —
    _lf_id "$row" "$session" || return 1     # a malformed lease grants nothing to anyone.
    [ "$(_lf_lease_field "$row" row)" = "$row" ] || return 1
    [[ "$(_lf_lease_field "$row" generation)" =~ ^[0-9]+$ ]] || return 1
    _lf_id "$(_lf_lease_field "$row" session)" || return 1
    _lf_cas "$row" "$session" "$gen" || return 1
    exp=$(_lf_lease_field "$row" expiry)
    [[ "$exp" =~ ^[0-9]+$ ]] || return 1
    now=$(_lf_now_ro) || return 1
    [ "$exp" -gt "$now" ]
}

_lf_pending_consumption() {  # an interrupted consumption at the CURRENT generation
    local gen
    gen=$(_lf_lease_field "$1" generation); gen=${gen:-0}
    [ -f "$LF_ROOT/consumed/$1.gen$gen" ]
}

# ---- lease ----------------------------------------------------------------------------------------
lf_acquire() {  # $1 row, $2 session, $3 ttl -> stdout: generation
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        local now gen
        now=$(_lf_now_ro) || exit 1
        [ -e "$LF_ROOT/compacted.$2" ] && exit 1
        [ -e "$LF_ROOT/rows/$1.rotate" ] && exit 1
        ls "$LF_ROOT/handoffs/$1."gen* >/dev/null 2>&1 && exit 1
        _lf_pending_consumption "$1" && exit 1
        gen=$(_lf_lease_field "$1" generation); gen=${gen:-0}
        [[ "$gen" =~ ^[0-9]+$ ]] || exit 1
        _lf_lease_live "$1" && exit 1
        _lf_crash before-lease-write
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$((gen + 1))
session=$2
expiry=$((now + $3))
EOF
        _lf_bump_floor "$now"
        _lf_crash after-lease-write
        echo $((gen + 1))
    ) 9>>"$LF_ROOT/.lock"
}

lf_renew() {  # $1 row, $2 session, $3 gen, $4 ttl — authority required (an expired owner re-acquires)
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_auth "$1" "$2" "$3" || exit 1
        local now; now=$(_lf_now_ro) || exit 1
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$3
session=$2
expiry=$((now + $4))
EOF
        _lf_bump_floor "$now"
    ) 9>>"$LF_ROOT/.lock"
}

lf_release() {  # $1 row, $2 session, $3 gen — refused while a rotation is pending (hand off!)
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_auth "$1" "$2" "$3" || exit 1
        [ -e "$LF_ROOT/rows/$1.rotate" ] && exit 1   # the boundary handoff is the only exit
        _lf_crash before-release
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$3
session=
expiry=0
EOF
        _lf_crash after-release
    ) 9>>"$LF_ROOT/.lock"
}

# ---- session <-> job mapping -------------------------------------------------------------------------
lf_start_job() {  # $1 row, $2 session, $3 gen, $4 job
    _lf_id "$1" "$2" "$4" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_auth "$1" "$2" "$3" || exit 1
        [ -e "$LF_ROOT/rows/$1.rotate" ] && exit 1
        [ -e "$LF_ROOT/compacted.$2" ] && exit 1
        _lf_crash before-job-write
        _lf_create "$LF_ROOT/jobs/$4" <<EOF || exit 1
row=$1
generation=$3
session=$2
EOF
        _lf_crash after-job-write
    ) 9>>"$LF_ROOT/.lock"
}

lf_jobs_of_lease() {  # $1 row, $2 gen — reverse trace; an UNREADABLE ledger fails the call
    _lf_id "$1" || return 1               # (round-5 blocking 3: unreadable state is never a
    [[ "$2" =~ ^[0-9]+$ ]] || return 1    # trusted empty), row regex-escaped, gen numeric
    local f
    [ -r "$LF_ROOT/jobs" ] || return 1
    for f in "$LF_ROOT/jobs/"*; do
        [ -e "$f" ] || continue
        [ -r "$f" ] || return 1
        if grep -q "^row=$(_lf_re "$1")\$" "$f" && grep -q "^generation=$2\$" "$f"; then
            basename "$f"
        fi
    done
}

# ---- rotation signals -----------------------------------------------------------------------------------
lf_soft_trip() {  # $1 row, $2 session, $3 gen
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_auth "$1" "$2" "$3" || exit 1
        _lf_write "$LF_ROOT/rows/$1.rotate" <<EOF
row=$1
requested_by=$2
generation=$3
EOF
    ) 9>>"$LF_ROOT/.lock"
}

lf_compaction() {  # $1 session
    _lf_id "$1" || return 1
    _lf_halt || return 9
    ( flock -x 9; _lf_halt || exit 9; _lf_write "$LF_ROOT/compacted.$1" <<< "1" ) 9>>"$LF_ROOT/.lock"
}

# ---- safe boundary ---------------------------------------------------------------------------------------
lf_commit_boundary() {  # $1 row, $2 session, $3 gen
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_auth "$1" "$2" "$3" || exit 1
        local jobs_list jobs
        jobs_list=$(lf_jobs_of_lease "$1" "$3") || exit 1   # unreadable ledger ABORTS — never
        jobs=$(printf '%s\n' "$jobs_list" | paste -sd, -)   # a trusted-empty handoff
        _lf_crash before-handoff-write
        _lf_write "$LF_ROOT/handoffs/$1.gen$3" <<EOF
row=$1
from_generation=$3
from_session=$2
jobs=$jobs
source=ledger
EOF
        _lf_crash after-handoff-write
        # the released lease RECORDS the departing session (last_session): handoff consumption
        # verifies the named predecessor against this ledger field unconditionally, jobs or not
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$3
session=
expiry=0
last_session=$2
EOF
        _lf_crash after-boundary-release
        [ -e "$LF_ROOT/rows/$1.rotate" ] && _lf_remove "$LF_ROOT/rows/$1.rotate"
        true
    ) 9>>"$LF_ROOT/.lock"
}

_lf_handoff_valid() {  # $1 handoff-path, $2 row, $3 expected-generation — EXACT, closed-world
    local h=$1 row=$2 gen=$3 rr fs jobs ledger_jobs jsess
    rr=$(_lf_re "$row")
    # CLOSED WORLD: every line must be a known field — an injected line (e.g. successor=evil)
    # refuses outright instead of riding into the consumed record
    grep -qvE '^(row|from_generation|from_session|jobs|source)=' "$h" && return 1
    # exactly one of each required field, no contradictory duplicates
    [ "$(grep -c '^row=' "$h")" = 1 ] || return 1
    [ "$(grep -c '^from_generation=' "$h")" = 1 ] || return 1
    [ "$(grep -c '^from_session=' "$h")" = 1 ] || return 1
    [ "$(grep -c '^jobs=' "$h")" = 1 ] || return 1
    [ "$(grep -c '^source=' "$h")" = 1 ] || return 1
    grep -q "^row=$rr\$" "$h" || return 1
    grep -q "^from_generation=$gen\$" "$h" || return 1
    fs=$(sed -n 's/^from_session=//p' "$h")
    _lf_id "$fs" || return 1
    grep -q '^source=ledger$' "$h" || return 1
    # the jobs field must EQUAL the ledger's recomputed reverse trace — self-assertion refused,
    # and an UNREADABLE ledger refuses (never a trusted empty)
    jobs=$(sed -n 's/^jobs=//p' "$h")
    local ledger_list
    ledger_list=$(lf_jobs_of_lease "$row" "$gen") || return 1
    ledger_jobs=$(printf '%s\n' "$ledger_list" | paste -sd, -)
    [ "$jobs" = "$ledger_jobs" ] || return 1
    # PROVENANCE, unconditional: the named predecessor must be the session the released lease
    # RECORDED at the boundary (last_session — present for every boundary handoff), AND every
    # job record of that generation must name the same session (mixed/malformed records refuse)
    [ "$fs" = "$(_lf_lease_field "$row" last_session)" ] || return 1
    local j
    for j in ${ledger_jobs//,/ }; do
        jsess=$(sed -n 's/^session=//p' "$LF_ROOT/jobs/$j")
        [ "$fs" = "$jsess" ] || return 1
    done
}

lf_consume_handoff() {  # $1 row, $2 successor — one locked transaction; successor IN CONTENT
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_lease_live "$1" && exit 1
        [ -e "$LF_ROOT/compacted.$2" ] && exit 1
        # an interrupted consumption already RECORDED its successor — only lf_recover_finish
        # may proceed; a second consumer must never overwrite that record
        _lf_pending_consumption "$1" && exit 1
        local n h now gen
        n=$(ls -1 "$LF_ROOT/handoffs/$1."gen* 2>/dev/null | wc -l)
        [ "$n" -eq 1 ] || exit 1
        h=$(ls -1 "$LF_ROOT/handoffs/$1."gen*)
        now=$(_lf_now_ro) || exit 1
        gen=$(_lf_lease_field "$1" generation); gen=${gen:-0}
        [[ "$gen" =~ ^[0-9]+$ ]] || exit 1
        _lf_handoff_valid "$h" "$1" "$gen" || exit 1
        # read the handoff content FIRST, checked — a failed read aborts before any transition
        # (round-5 blocking 4: no successor-only partial records)
        local hcontent
        hcontent=$(cat "$h") || exit 1
        _lf_crash before-consume
        # 1) durable consumption record: successor named IN CONTENT (dot-safe), fixed filename
        { echo "successor=$2"; printf '%s\n' "$hcontent"; } | _lf_write "$LF_ROOT/consumed/$1.gen$gen"
        _lf_crash after-consume-record
        # 2) retire the handoff
        _lf_remove "$h"
        _lf_crash after-handoff-retire
        # 3) mint the successor lease
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$((gen + 1))
session=$2
expiry=$((now + 300))
EOF
        _lf_bump_floor "$now"
        _lf_crash after-successor-lease
        [ -e "$LF_ROOT/rows/$1.rotate" ] && _lf_remove "$LF_ROOT/rows/$1.rotate"
        echo $((gen + 1))
    ) 9>>"$LF_ROOT/.lock"
}

# ---- respawn / dead-letter ---------------------------------------------------------------------------------
lf_respawn() {  # $1 row, $2 supervisor-token
    _lf_id "$1" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        [ "$2" = "$(cat "$LF_ROOT/supervisor")" ] || exit 1
        _lf_dead "$1" || exit 3
        local n=0 f="$LF_ROOT/respawns/$1"
        [ -f "$f" ] && n=$(cat "$f")
        [[ "$n" =~ ^[0-9]+$ ]] || exit 1
        n=$((n + 1))
        if [ "$n" -ge 3 ]; then
            _lf_write "$LF_ROOT/deadletters/$1" <<EOF
row=$1
reason=doom-loop: 3 consecutive respawns without recorded useful activity
EOF
            exit 3
        fi
        _lf_write "$f" <<< "$n"
    ) 9>>"$LF_ROOT/.lock"
}

lf_activity() {  # $1 row, $2 session, $3 gen
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_auth "$1" "$2" "$3" || exit 1
        [ -e "$LF_ROOT/respawns/$1" ] && _lf_remove "$LF_ROOT/respawns/$1"
        true
    ) 9>>"$LF_ROOT/.lock"
}

lf_safety_flag() {  # $1 row, $2 session, $3 gen
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_auth "$1" "$2" "$3" || exit 1
        _lf_write "$LF_ROOT/deadletters/$1" <<EOF
row=$1
generation=$3
reason=safety-flagged turn
EOF
    ) 9>>"$LF_ROOT/.lock"
}

# ---- classified liveness -> kill / prompt ------------------------------------------------------------------
lf_observe() {  # $1 session, $2 class, $3 identity, $4 row, $5 gen, $6 tick-label
    _lf_id "$1" "$3" "$4" "$5" "$6" || return 1
    case "$2" in stale|unknown) ;; *) return 1 ;; esac
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$4" || exit 3
        local seq
        seq=$(cat "$LF_ROOT/.obs_seq"); seq=$((seq + 1))
        _lf_write "$LF_ROOT/.obs_seq" <<< "$seq"
        _lf_write "$LF_ROOT/observations/$1.$(printf '%08d' "$seq")" <<EOF
class=$2
identity=$3
row=$4
generation=$5
tick=$6
EOF
    ) 9>>"$LF_ROOT/.lock"
}

_lf_kill_ok() {
    local session=$1 identity=$2 row=$3 gen=$4 last2 f t1 t2
    [ -e "$LF_ROOT/foreign-claude" ] && return 1
    [ -e "$LF_ROOT/deadletters/$row" ] && return 1
    last2=$(ls -1 "$LF_ROOT/observations/$session."* 2>/dev/null | sort | tail -2)
    [ "$(printf '%s\n' "$last2" | grep -c .)" -eq 2 ] || return 1
    t1=$(sed -n 's/^tick=//p' "$(printf '%s\n' "$last2" | head -1)")
    t2=$(sed -n 's/^tick=//p' "$(printf '%s\n' "$last2" | tail -1)")
    [ -n "$t1" ] && [ -n "$t2" ] && [ "$t1" != "$t2" ] || return 1
    for f in $last2; do
        [ "$(sed -n 's/^class=//p' "$f")" = "stale" ] || return 1
        [ "$(sed -n 's/^identity=//p' "$f")" = "$identity" ] || return 1
        [ "$(sed -n 's/^row=//p' "$f")" = "$row" ] || return 1
        [ "$(sed -n 's/^generation=//p' "$f")" = "$gen" ] || return 1
    done
    # FULL authority, not bare CAS (round-5 blocking 2): a forged/malformed/expired lease can
    # never authorize a kill — the same whole-schema + strictly-live rule as every authority op
    _lf_auth "$row" "$session" "$gen"
}

lf_kill_eligible() {
    _lf_id "$1" "$2" "$3" || return 1
    _lf_halt || return 9
    ( flock -x 9; _lf_halt || exit 9; _lf_kill_ok "$1" "$2" "$3" "$4" ) 9>>"$LF_ROOT/.lock"
}

lf_kill() {
    _lf_id "$1" "$2" "$3" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_kill_ok "$1" "$2" "$3" "$4" || exit 1
        _lf_write "$LF_ROOT/killed/$1" <<< "row=$3 gen=$4 identity=$2"
    ) 9>>"$LF_ROOT/.lock"
}

lf_type() {  # $1 session, $2 row, $3 gen, $4 text — a prompt reaches ONLY the row's live
    _lf_id "$1" "$2" || return 1        # authority holder, never a dead-lettered row, never
    _lf_halt || return 9                # during standby, never under HALT.
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$2" || exit 3
        [ -e "$LF_ROOT/foreign-claude" ] && exit 1
        _lf_auth "$2" "$1" "$3" || exit 1
        _lf_write "$LF_ROOT/typed.$1" <<< "$4"
    ) 9>>"$LF_ROOT/.lock"
}

# ---- crash recovery -----------------------------------------------------------------------------------------
lf_recover() {  # $1 row -> ONE answer; read-only; dead-letters outrank everything but HALT
    _lf_id "$1" || return 1
    (
        flock -x 9
        local sess gen c
        if [ -e "$LF_ROOT/deadletters/$1" ]; then
            echo "dead-lettered"
            exit 0
        fi
        sess=$(_lf_lease_field "$1" session)
        gen=$(_lf_lease_field "$1" generation); gen=${gen:-0}
        if [ -n "$sess" ] && _lf_lease_live "$1"; then
            # a live-LOOKING lease must also be whole-schema valid before recovery names a
            # promptable owner (round-5 blocking 2) — a forged/malformed record fails closed
            if [ "$(_lf_lease_field "$1" row)" = "$1" ] \
               && [[ "$(_lf_lease_field "$1" generation)" =~ ^[0-9]+$ ]] \
               && _lf_id "$sess"; then
                echo "owner $sess"
            else
                echo "invalid-lease"
            fi
        elif [ -f "$LF_ROOT/consumed/$1.gen$gen" ]; then
            # a consumption committed at the CURRENT generation outranks a lingering handoff:
            # the successor is already durably recorded (content field, dot-safe)
            echo "consumed-by $(sed -n 's/^successor=//p' "$LF_ROOT/consumed/$1.gen$gen")"
        elif ls "$LF_ROOT/handoffs/$1."gen* >/dev/null 2>&1; then
            echo "handoff-ready"
        else
            echo "released"
        fi
    ) 9>>"$LF_ROOT/.lock"
}

lf_recover_finish() {  # $1 row — retire any leftover handoff, mint the RECORDED successor
    _lf_id "$1" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_lease_live "$1" && exit 1
        local now gen succ h
        gen=$(_lf_lease_field "$1" generation); gen=${gen:-0}
        [ -f "$LF_ROOT/consumed/$1.gen$gen" ] || exit 1
        succ=$(sed -n 's/^successor=//p' "$LF_ROOT/consumed/$1.gen$gen")
        _lf_id "$succ" || exit 1
        # N=1 holds through recovery (round-5 blocking 5): a successor compacted between the
        # interrupted consumption and this recovery gets NO lease — the row stays fenced for
        # the owner/authorized procedure, honestly, rather than violating the hard ceiling
        [ -e "$LF_ROOT/compacted.$succ" ] && exit 1
        now=$(_lf_now_ro) || exit 1
        h=$(ls -1 "$LF_ROOT/handoffs/$1."gen* 2>/dev/null | head -1)
        [ -n "$h" ] && _lf_remove "$h"
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$((gen + 1))
session=$succ
expiry=$((now + 300))
EOF
        _lf_bump_floor "$now"
        echo "$succ"
    ) 9>>"$LF_ROOT/.lock"
}
