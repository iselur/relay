#!/usr/bin/env bash
# THROWAWAY lifecycle prototype (R77 / PLAN-007, earliest falsifiable proof). This file is the
# disposable design under test — per-row leases, ledger-derived handoff, duplicate suppression,
# HALT precedence, dead-letters, classified-liveness kills — operating ONLY under a caller-owned
# temporary root (LF_ROOT). It touches no production settings, ledger, sessions, or credentials,
# and nothing outside tests/ may source it. The production implementation is written LATER,
# against what this prototype proves; do not promote this file into an installed code path.
#
# Conventions: every mutator (a) refuses when $LF_ROOT/HALT exists — HALT outranks everything;
# (b) serializes on ONE flock ($LF_ROOT/.lock); (c) writes durably via tmp+mv in the same
# directory; (d) honors LF_CRASH_POINT=<name> by dying (exit 97) at the named point, which the
# falsifier uses to build its crash matrix. Return codes: 0 ok; 1 refused (CAS/authority);
# 3 dead-lettered; 9 HALT.

set -u

lf_now() { date +%s; }

lf_init() {  # $1 root
    LF_ROOT="$1"
    mkdir -p "$LF_ROOT"/{rows,jobs,handoffs,consumed,deadletters,observations,respawns}
    : > "$LF_ROOT/.lock"
}

_lf_crash() { [ "${LF_CRASH_POINT:-}" = "$1" ] && exit 97; return 0; }
_lf_halt()  { [ -e "$LF_ROOT/HALT" ] && return 9; return 0; }

_lf_write() {  # $1 path, stdin content — atomic tmp+mv in the target dir
    local tmp
    tmp="$(mktemp "$(dirname "$1")/.tmp.XXXXXX")"
    cat > "$tmp"
    mv "$tmp" "$1"
}

_lf_lease_field() {  # $1 row, $2 field — empty when absent
    [ -f "$LF_ROOT/rows/$1.lease" ] || return 0
    sed -n "s/^$2=//p" "$LF_ROOT/rows/$1.lease"
}

# ---- lease: acquire / renew / release (CAS on session+generation) ---------------------------
lf_acquire() {  # $1 row, $2 session, $3 ttl_s -> stdout: generation
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        local row=$1 session=$2 ttl=$3 gen cur_sess cur_exp now
        now=$(lf_now)
        # a session that has hit its compaction ceiling acquires NOTHING further (N=1)
        [ -e "$LF_ROOT/compacted.$session" ] && exit 1
        # a dead-lettered row is fenced until a NEW generation is created by an authorized
        # recovery — the prototype models that as: acquire refuses outright.
        [ -e "$LF_ROOT/deadletters/$row" ] && exit 3
        cur_sess=$(_lf_lease_field "$row" session)
        cur_exp=$(_lf_lease_field "$row" expiry)
        gen=$(_lf_lease_field "$row" generation); gen=${gen:-0}
        if [ -n "$cur_sess" ] && [ "$cur_sess" != "$session" ]; then
            # unexpired foreign lease -> refuse; malformed/backward expiry -> refuse takeover
            [[ "$cur_exp" =~ ^[0-9]+$ ]] || exit 1
            [ "$cur_exp" -gt "$now" ] && exit 1
        fi
        _lf_crash before-lease-write
        _lf_write "$LF_ROOT/rows/$row.lease" <<EOF
row=$row
generation=$((gen + 1))
session=$session
expiry=$((now + ttl))
EOF
        _lf_crash after-lease-write
        echo $((gen + 1))
    ) 9>>"$LF_ROOT/.lock"
}

_lf_cas() {  # $1 row, $2 session, $3 gen — inside-lock ownership check
    [ "$(_lf_lease_field "$1" session)" = "$2" ] && [ "$(_lf_lease_field "$1" generation)" = "$3" ]
}

lf_renew() {  # $1 row, $2 session, $3 gen, $4 ttl_s
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_cas "$1" "$2" "$3" || exit 1
        local now; now=$(lf_now)
        _lf_write "$LF_ROOT/rows/$1.lease" <<EOF
row=$1
generation=$3
session=$2
expiry=$((now + $4))
EOF
    ) 9>>"$LF_ROOT/.lock"
}

lf_release() {  # $1 row, $2 session, $3 gen
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
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

# ---- session <-> job mapping with duplicate suppression --------------------------------------
lf_start_job() {  # $1 row, $2 session, $3 gen, $4 job_id
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_cas "$1" "$2" "$3" || exit 1
        # rotation requested at a soft threshold: the CURRENT job finishes, NEW work refuses
        [ -e "$LF_ROOT/rows/$1.rotate" ] && exit 1
        [ -e "$LF_ROOT/deadletters/$1" ] && exit 3
        _lf_crash before-job-write
        ( set -C; printf 'row=%s\ngeneration=%s\nsession=%s\n' "$1" "$3" "$2" \
            > "$LF_ROOT/jobs/$4" ) 2>/dev/null || exit 1   # noclobber: exactly-once
        _lf_crash after-job-write
    ) 9>>"$LF_ROOT/.lock"
}

# ---- soft/hard rotation signals ---------------------------------------------------------------
lf_soft_trip() {  # $1 row — request rotation at the NEXT safe boundary; never mid-task
    _lf_halt || return 9
    ( flock -x 9; _lf_halt || exit 9; : > "$LF_ROOT/rows/$1.rotate" ) 9>>"$LF_ROOT/.lock"
}

lf_compaction() {  # $1 session — first classified compaction = the hard ceiling (N=1)
    _lf_halt || return 9
    ( flock -x 9; _lf_halt || exit 9; : > "$LF_ROOT/compacted.$1" ) 9>>"$LF_ROOT/.lock"
}

# ---- safe boundary: ledger-derived handoff, atomic commit + release --------------------------
lf_commit_boundary() {  # $1 row, $2 session, $3 gen
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        _lf_cas "$1" "$2" "$3" || exit 1
        # the handoff is built ONLY from durable records: the lease and the job map — never
        # from a transcript, summary, or prose. Everything below is re-read from disk.
        local jobs
        jobs=$(grep -l "^row=$1\$" "$LF_ROOT/jobs/"* 2>/dev/null | xargs -rn1 basename | paste -sd, -)
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

lf_consume_handoff() {  # $1 row, $2 new_session — one-time consumption, then fresh acquire
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        local h
        h=$(ls "$LF_ROOT/handoffs/$1."gen* 2>/dev/null | head -1)
        [ -n "$h" ] || exit 1
        grep -q '^source=ledger$' "$h" || exit 1   # refuse a handoff not marked ledger-derived
        _lf_crash before-consume
        mv "$h" "$LF_ROOT/consumed/$(basename "$h").$2" || exit 1   # atomic: second consumer loses
        _lf_crash after-consume
    ) 9>>"$LF_ROOT/.lock"
}

# ---- respawn dead-letter (3 strikes) + immediate safety dead-letter ---------------------------
lf_respawn() {  # $1 row — returns 3 + dead-letter on the third consecutive activity-free respawn
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        local n=0 f="$LF_ROOT/respawns/$1"
        [ -e "$LF_ROOT/deadletters/$1" ] && exit 3
        [ -f "$f" ] && n=$(cat "$f")
        n=$((n + 1))
        if [ "$n" -ge 3 ]; then
            _lf_write "$LF_ROOT/deadletters/$1" <<EOF
row=$1
reason=doom-loop: 3 consecutive respawns without recorded useful activity
EOF
            exit 3
        fi
        echo "$n" > "$f"
    ) 9>>"$LF_ROOT/.lock"
}

lf_activity() {  # $1 row — recorded useful activity resets the respawn counter
    _lf_halt || return 9
    ( flock -x 9; _lf_halt || exit 9; rm -f "$LF_ROOT/respawns/$1" ) 9>>"$LF_ROOT/.lock"
}

lf_safety_flag() {  # $1 row, $2 gen — immediate dead-letter, bound to row+generation
    _lf_halt || return 9
    (
        flock -x 9
        _lf_halt || exit 9
        [ "$(_lf_lease_field "$1" generation)" = "$2" ] || exit 1  # never a different/fresh gen
        _lf_write "$LF_ROOT/deadletters/$1" <<EOF
row=$1
generation=$2
reason=safety-flagged turn
EOF
    ) 9>>"$LF_ROOT/.lock"
}

# ---- classified liveness -> kill eligibility ---------------------------------------------------
lf_observe() {  # $1 session, $2 class(stale|unknown), $3 tmux_identity — one tick's observation
    ( flock -x 9; printf '%s %s %s\n' "$2" "$3" "$(lf_now)" >> "$LF_ROOT/observations/$1" ) \
        9>>"$LF_ROOT/.lock"
}

lf_kill_eligible() {  # $1 session, $2 expected_tmux_identity, $3 row, $4 gen — rc 0 = eligible
    _lf_halt || return 9
    [ -e "$LF_ROOT/foreign-claude" ] && return 1        # user-presence standby: never act
    (
        flock -x 9
        _lf_halt || exit 9
        local f="$LF_ROOT/observations/$1" n
        [ -f "$f" ] || exit 1
        # repeated (>=2) CLASSIFIED 'stale' observations, all for the SAME verified identity
        n=$(grep -c "^stale $2 " "$f" 2>/dev/null || true)
        [ "${n:-0}" -ge 2 ] || exit 1
        grep -qv "^stale $2 \|^unknown" "$f" && exit 1   # any other identity's 'stale' poisons
        _lf_cas "$3" "$1" "$4" || exit 1                 # kill binds to the row+gen it owns
    ) 9>>"$LF_ROOT/.lock"
}

# ---- crash recovery ----------------------------------------------------------------------------
lf_recover() {  # $1 row -> stdout: 'owner <session>' | 'handoff-ready' | 'released'
    (
        flock -x 9
        local sess exp now
        sess=$(_lf_lease_field "$1" session)
        exp=$(_lf_lease_field "$1" expiry)
        now=$(lf_now)
        # half-written temp files are ignored by construction (tmp+mv); the durable records
        # alone decide: a live unexpired lease has ONE owner; else a committed, unconsumed
        # handoff feeds exactly one successor; else the row is released.
        if [ -n "$sess" ] && [[ "$exp" =~ ^[0-9]+$ ]] && [ "$exp" -gt "$now" ]; then
            echo "owner $sess"
        elif ls "$LF_ROOT/handoffs/$1."gen* >/dev/null 2>&1; then
            echo "handoff-ready"
        else
            echo "released"
        fi
    ) 9>>"$LF_ROOT/.lock"
}
