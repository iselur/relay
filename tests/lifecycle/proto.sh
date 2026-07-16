#!/usr/bin/env bash
# THROWAWAY lifecycle prototype (R77 / PLAN-007, earliest falsifiable proof) — round-2 revision.
# This file is the disposable design under test; it operates ONLY under a caller-owned temporary
# root (LF_ROOT), touches no production state, and nothing outside tests/ may source it.
#
# Design rules (each falsifier-enforced):
# - IDENTIFIERS: every row/session/job/identity id is [A-Za-z0-9._-]+; anything else refuses
#   (no path escape from LF_ROOT).
# - LOCKING: one flock ($LF_ROOT/.lock) serializes every mutation.
# - HALT: checked at entry AND immediately before EVERY durable mutation (rc 9). It outranks
#   everything, including dead-letters and kills.
# - CLOCK: _lf_checked_now fails closed on an unreadable or BACKWARD clock (monotonic floor in
#   $LF_ROOT/.last_now); no mutation proceeds on bad time.
# - DURABILITY: every record is written tmp+fsyncless mv (_lf_write); exactly-once records
#   (jobs) are tmp+ln (atomic create-or-fail). No trusted partial writes exist.
# - CAS: every row mutation by a session requires (session, generation) to match the lease.
#   Supervisor-side ops (respawn) require the supervisor token recorded at init.
# - DEAD-LETTER: fences EVERY mutation on the row (rc 3); recovery is not automatic.
# - HANDOFF: built from durable records only; consumable only once the from-lease is released
#   or expired; consumption records the successor durably BEFORE the successor lease is minted,
#   so crash recovery always finds one owner or one recorded next action.
# - CRASH INJECTION: LF_CRASH_POINT=<name> exits 97 at the named point for the crash matrix.
# Return codes: 0 ok; 1 refused; 3 dead-lettered; 9 HALT.

set -u

lf_init() {  # $1 root, $2 supervisor-token
    LF_ROOT="$1"
    mkdir -p "$LF_ROOT"/{rows,jobs,handoffs,consumed,deadletters,observations,respawns,killed}
    : > "$LF_ROOT/.lock"
    printf '%s' "${2:-supervisor}" > "$LF_ROOT/supervisor"
}

_lf_id() {  # each argument must be a safe identifier
    local a
    for a in "$@"; do
        case "$a" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    done
}

_lf_crash() { [ "${LF_CRASH_POINT:-}" = "$1" ] && exit 97; return 0; }
_lf_halt()  { [ -e "$LF_ROOT/HALT" ] && return 9; return 0; }
_lf_dead()  { [ -e "$LF_ROOT/deadletters/$1" ] && return 3; return 0; }

_lf_checked_now() {  # monotonic, fail-closed clock; prints epoch seconds
    local now last
    now=$(date +%s 2>/dev/null) || return 1
    [[ "$now" =~ ^[0-9]+$ ]] || return 1
    last=$(cat "$LF_ROOT/.last_now" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    [ "$now" -lt "$last" ] && return 1          # clock went backward: refuse
    printf '%s' "$now" > "$LF_ROOT/.last_now.tmp" && mv "$LF_ROOT/.last_now.tmp" "$LF_ROOT/.last_now"
    echo "$now"
}

_lf_write() {  # $1 path, stdin content — atomic tmp+mv, HALT re-checked at the write boundary
    _lf_halt || exit 9
    local tmp
    tmp="$(mktemp "$(dirname "$1")/.tmp.XXXXXX")"
    cat > "$tmp"
    mv "$tmp" "$1"
}

_lf_create() {  # $1 path, stdin content — atomic exactly-once (tmp+ln); rc 1 when it exists
    _lf_halt || exit 9
    local tmp
    tmp="$(mktemp "$(dirname "$1")/.tmp.XXXXXX")"
    cat > "$tmp"
    if ln "$tmp" "$1" 2>/dev/null; then rm -f "$tmp"; return 0; fi
    rm -f "$tmp"; return 1
}

_lf_lease_field() {  # $1 row, $2 field
    [ -f "$LF_ROOT/rows/$1.lease" ] || return 0
    sed -n "s/^$2=//p" "$LF_ROOT/rows/$1.lease"
}

_lf_cas() {  # $1 row, $2 session, $3 gen
    [ "$(_lf_lease_field "$1" session)" = "$2" ] && [ "$(_lf_lease_field "$1" generation)" = "$3" ]
}

_lf_lease_live() {  # $1 row — rc 0 when owned and unexpired (malformed expiry counts as LIVE:
    local sess exp now  # a corrupt lease must fence takeover, not permit it)
    sess=$(_lf_lease_field "$1" session)
    [ -n "$sess" ] || return 1
    exp=$(_lf_lease_field "$1" expiry)
    [[ "$exp" =~ ^[0-9]+$ ]] || return 0
    now=$(_lf_checked_now) || return 0
    [ "$exp" -gt "$now" ]
}

# ---- lease ------------------------------------------------------------------------------------
lf_acquire() {  # $1 row, $2 session, $3 ttl -> stdout: generation
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        local now gen cur_sess
        now=$(_lf_checked_now) || exit 1
        [ -e "$LF_ROOT/compacted.$2" ] && exit 1        # N=1: no further acquisition
        [ -e "$LF_ROOT/rows/$1.rotate" ] && exit 1      # rotation pending: acquire via handoff
        ls "$LF_ROOT/handoffs/$1."gen* >/dev/null 2>&1 && exit 1  # unconsumed handoff pending:
        # the row's continuity belongs to a successor via lf_consume_handoff, never a bare grab
        cur_sess=$(_lf_lease_field "$1" session)
        gen=$(_lf_lease_field "$1" generation); gen=${gen:-0}
        [[ "$gen" =~ ^[0-9]+$ ]] || exit 1
        if _lf_lease_live "$1"; then
            exit 1   # live lease refuses EVERY acquire — the owner renews, never re-acquires
        fi
        _lf_crash before-lease-write
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$((gen + 1))
session=$2
expiry=$((now + $3))
EOF
        _lf_crash after-lease-write
        echo $((gen + 1))
    ) 9>>"$LF_ROOT/.lock"
}

lf_renew() {  # $1 row, $2 session, $3 gen, $4 ttl
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_cas "$1" "$2" "$3" || exit 1
        local now; now=$(_lf_checked_now) || exit 1
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$3
session=$2
expiry=$((now + $4))
EOF
    ) 9>>"$LF_ROOT/.lock"
}

lf_release() {  # $1 row, $2 session, $3 gen
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_cas "$1" "$2" "$3" || exit 1
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

# ---- session <-> job mapping (both directions) -------------------------------------------------
lf_start_job() {  # $1 row, $2 session, $3 gen, $4 job
    _lf_id "$1" "$2" "$4" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_cas "$1" "$2" "$3" || exit 1
        [ -e "$LF_ROOT/rows/$1.rotate" ] && exit 1       # rotation pending: no new work
        [ -e "$LF_ROOT/compacted.$2" ] && exit 1         # compacted session: hand off, not work
        _lf_crash before-job-write
        _lf_create "$LF_ROOT/jobs/$4" <<EOF || exit 1
row=$1
generation=$3
session=$2
EOF
        _lf_crash after-job-write
    ) 9>>"$LF_ROOT/.lock"
}

lf_jobs_of_lease() {  # $1 row, $2 gen — reverse trace: the jobs this lease authorized
    grep -l "^row=$1\$" "$LF_ROOT/jobs/"* 2>/dev/null \
        | xargs -r grep -l "^generation=$2\$" | xargs -rn1 basename
}

# ---- rotation signals ---------------------------------------------------------------------------
lf_soft_trip() {  # $1 row, $2 session, $3 gen — only the owner requests its own rotation
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_cas "$1" "$2" "$3" || exit 1
        _lf_write "$LF_ROOT/rows/$1.rotate" <<EOF
row=$1
requested_by=$2
generation=$3
EOF
    ) 9>>"$LF_ROOT/.lock"
}

lf_compaction() {  # $1 session — N=1 hard ceiling marker
    _lf_id "$1" || return 1
    _lf_halt || return 9
    ( flock -x 9; _lf_halt || exit 9; _lf_write "$LF_ROOT/compacted.$1" <<< "1" ) 9>>"$LF_ROOT/.lock"
}

# ---- safe boundary: ledger-derived handoff -----------------------------------------------------
lf_commit_boundary() {  # $1 row, $2 session, $3 gen
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_cas "$1" "$2" "$3" || exit 1
        local jobs
        jobs=$(lf_jobs_of_lease "$1" "$3" | paste -sd, -)
        _lf_crash before-handoff-write
        _lf_write "$LF_ROOT/handoffs/$1.gen$3" <<EOF
row=$1
from_generation=$3
from_session=$2
jobs=$jobs
source=ledger
EOF
        _lf_crash after-handoff-write
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$3
session=
expiry=0
EOF
        _lf_crash after-boundary-release
        rm -f "$LF_ROOT/rows/$1.rotate"
    ) 9>>"$LF_ROOT/.lock"
}

lf_consume_handoff() {  # $1 row, $2 successor — ONE transaction: record successor, mint lease
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_lease_live "$1" && exit 1          # a live from-lease means NOT at the boundary yet
        local h now gen
        h=$(ls "$LF_ROOT/handoffs/$1."gen* 2>/dev/null | head -1)
        [ -n "$h" ] || exit 1
        grep -q '^source=ledger$' "$h" || exit 1
        now=$(_lf_checked_now) || exit 1
        gen=$(_lf_lease_field "$1" generation); gen=${gen:-0}
        [[ "$gen" =~ ^[0-9]+$ ]] || exit 1
        _lf_crash before-consume
        mv "$h" "$LF_ROOT/consumed/$(basename "$h").$2" || exit 1   # durable successor record
        _lf_crash after-consume
        # the successor's lease is minted INSIDE the same locked transaction; a crash between
        # the two durable writes leaves the consumed/<...>.<successor> record, from which
        # lf_recover names the one recorded owner (no lost work, no second consumer).
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$((gen + 1))
session=$2
expiry=$((now + 300))
EOF
        _lf_crash after-successor-lease
        echo $((gen + 1))
    ) 9>>"$LF_ROOT/.lock"
}

# ---- respawn / dead-letter ----------------------------------------------------------------------
lf_respawn() {  # $1 row, $2 supervisor-token — only the supervisor counts respawns
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

lf_activity() {  # $1 row, $2 session, $3 gen — only the OWNING session records useful activity
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_cas "$1" "$2" "$3" || exit 1
        rm -f "$LF_ROOT/respawns/$1"
    ) 9>>"$LF_ROOT/.lock"
}

lf_safety_flag() {  # $1 row, $2 session, $3 gen — immediate dead-letter, full CAS binding
    _lf_id "$1" "$2" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_cas "$1" "$2" "$3" || exit 1
        _lf_write "$LF_ROOT/deadletters/$1" <<EOF
row=$1
generation=$3
reason=safety-flagged turn
EOF
    ) 9>>"$LF_ROOT/.lock"
}

# ---- classified liveness -> kill ----------------------------------------------------------------
lf_observe() {  # $1 session, $2 class(stale|unknown), $3 identity, $4 row, $5 gen, $6 tick
    _lf_id "$1" "$3" "$4" "$6" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_write "$LF_ROOT/observations/$1.$6" <<EOF
class=$2
identity=$3
row=$4
generation=$5
tick=$6
EOF
    ) 9>>"$LF_ROOT/.lock"
}

_lf_kill_ok() {  # inside-lock eligibility: the LAST TWO observations for the session must be
    # 'stale', on distinct ticks, and every field must match the verified identity, row, AND
    # lease generation — an intervening 'unknown' or any mismatch vetoes; old generations
    # cannot be replayed against a new lease.
    local session=$1 identity=$2 row=$3 gen=$4 last2 f
    [ -e "$LF_ROOT/foreign-claude" ] && return 1
    last2=$(ls -1 "$LF_ROOT/observations/$session."* 2>/dev/null | sort | tail -2)
    [ "$(printf '%s\n' "$last2" | grep -c .)" -eq 2 ] || return 1
    local t1 t2
    t1=$(basename "$(printf '%s\n' "$last2" | head -1)")
    t2=$(basename "$(printf '%s\n' "$last2" | tail -1)")
    [ "$t1" != "$t2" ] || return 1
    for f in $last2; do
        grep -q '^class=stale$' "$f" || return 1
        grep -q "^identity=$identity\$" "$f" || return 1
        grep -q "^row=$row\$" "$f" || return 1
        grep -q "^generation=$gen\$" "$f" || return 1
    done
    _lf_cas "$row" "$session" "$gen"
}

lf_kill_eligible() {  # $1 session, $2 identity, $3 row, $4 gen — advisory probe
    _lf_id "$1" "$2" "$3" || return 1
    _lf_halt || return 9
    ( flock -x 9; _lf_halt || exit 9; _lf_kill_ok "$1" "$2" "$3" "$4" ) 9>>"$LF_ROOT/.lock"
}

lf_kill() {  # $1 session, $2 identity, $3 row, $4 gen — the ACTION revalidates everything at
    _lf_id "$1" "$2" "$3" || return 1     # the action boundary (TOCTOU close): HALT, standby,
    _lf_halt || return 9                  # observations, identity, and generation, inside the lock.
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_kill_ok "$1" "$2" "$3" "$4" || exit 1
        _lf_write "$LF_ROOT/killed/$1" <<< "row=$3 gen=$4 identity=$2"
    ) 9>>"$LF_ROOT/.lock"
}

lf_type() {  # $1 session, $2 text — a prompt/keystroke op: HALT + standby gate it like a kill
    _lf_id "$1" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        [ -e "$LF_ROOT/foreign-claude" ] && exit 1
        _lf_write "$LF_ROOT/typed.$1" <<< "$2"
    ) 9>>"$LF_ROOT/.lock"
}

# ---- crash recovery ------------------------------------------------------------------------------
lf_recover() {  # $1 row -> ONE answer: 'owner <s>' | 'handoff-ready' | 'consumed-by <s>' | 'released'
    (
        flock -x 9
        local sess gen c
        sess=$(_lf_lease_field "$1" session)
        gen=$(_lf_lease_field "$1" generation); gen=${gen:-0}
        if [ -n "$sess" ] && _lf_lease_live "$1"; then
            echo "owner $sess"                # a LIVE lease always wins — one owner
        elif ls "$LF_ROOT/handoffs/$1."gen* >/dev/null 2>&1; then
            echo "handoff-ready"              # an unconsumed handoff outranks history
        elif c=$(ls -1 "$LF_ROOT/consumed/$1.gen$gen".* 2>/dev/null | tail -1); [ -n "$c" ]; then
            # consumption recorded at THIS generation but the successor lease was never minted:
            # the durable record names exactly one successor — recovery re-mints for THAT
            # session (lf_recover_finish), never another. Historical consumed records carry
            # older generations and never match.
            echo "consumed-by ${c##*.}"
        else
            echo "released"
        fi
    ) 9>>"$LF_ROOT/.lock"
}

lf_recover_finish() {  # $1 row — complete an interrupted consumption for the RECORDED successor
    _lf_id "$1" || return 1
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_dead "$1" || exit 3
        _lf_lease_live "$1" && exit 1
        local c now gen
        gen=$(_lf_lease_field "$1" generation); gen=${gen:-0}
        c=$(ls -1 "$LF_ROOT/consumed/$1.gen$gen".* 2>/dev/null | tail -1)
        [ -n "$c" ] || exit 1
        now=$(_lf_checked_now) || exit 1
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$((gen + 1))
session=${c##*.}
expiry=$((now + 300))
EOF
        echo "${c##*.}"
    ) 9>>"$LF_ROOT/.lock"
}
