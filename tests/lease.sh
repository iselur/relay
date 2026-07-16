#!/usr/bin/env bash
# R77 / PLAN-007 gate 4: the per-intake-row task lease, production surface. scripts/lease is the
# falsifier-proven design (tests/lifecycle_falsifier.sh) shipped for real: monotonic generations,
# (session, generation) compare-and-set, fail-closed clock/corruption handling, HALT precedence,
# dead-letter fencing. Enforcement points per the reviewed entry-point inventory: intake
# close/observe (a LIVE lease fences them), dispatch launch tuple freezing, and continue/merge
# stale-authority refusals. A two-session barrier race and an expired-lease drill prove the
# brief's two required behaviors directly.
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=1; }

command -v flock >/dev/null 2>&1 || { echo "SKIP lease.sh: flock absent"; exit 77; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/.orchestrator"
cp -p scripts/lease scripts/intake "$tmp/scripts/"
cat > "$tmp/.orchestrator/REQUEST-LEDGER.md" <<'EOF'
| id | date | request | lane | plan-ref | status | completion-evidence |
| R90 | 07-16 | leased row | — | — | open | DONE WHEN: x |
| R91 | 07-16 | expired-lease row | — | — | open | DONE WHEN: x |
| R92 | 07-16 | unleased row | — | — | open | DONE WHEN: x |
EOF
cd "$tmp"

# ---- lease core ---------------------------------------------------------------------------------
g=$(scripts/lease acquire R90 --session sessA --ttl 60)
[ "$g" = "1" ] && ok "first acquire mints generation 1" || bad "first acquire minted '$g'"
scripts/lease acquire R90 --session sessA --ttl 60 >/dev/null 2>&1 \
  && bad "live owner re-acquired its own row (silent generation bump)" \
  || ok "a LIVE lease refuses every acquire — owners renew"
scripts/lease acquire R90 --session sessB --ttl 60 >/dev/null 2>&1 \
  && bad "foreign session grabbed a live lease" || ok "foreign session refused on a live lease"
scripts/lease check R90 --session sessA --generation 1 && ok "CAS check matches the owner" \
  || bad "owner CAS check failed"
scripts/lease check R90 --session sessB --generation 1 2>/dev/null \
  && bad "CAS matched a non-owner" || ok "CAS refuses a non-owner"
scripts/lease renew R90 --session sessA --generation 1 --ttl 60 && ok "owner renews" \
  || bad "owner renew failed"
scripts/lease renew R90 --session sessA --generation 9 --ttl 60 2>/dev/null \
  && bad "renew accepted a wrong generation" || ok "renew refuses a wrong generation"

# id sanitization
scripts/lease acquire "../evil" --session s 2>/dev/null && bad "path-escape row id accepted" \
  || ok "row id is sanitized (no path escape)"

# HALT precedence
: > .orchestrator/HALT
scripts/lease acquire R92 --session sessH 2>/dev/null; [ $? -eq 9 ] \
  && ok "HALT refuses acquire (rc 9)" || bad "HALT did not stop acquire"
scripts/lease renew R90 --session sessA --generation 1 --ttl 60 2>/dev/null; [ $? -eq 9 ] \
  && ok "HALT refuses renew" || bad "HALT did not stop renew"
rm .orchestrator/HALT

# backward clock fails closed
echo $(( $(date +%s) + 99999 )) > .orchestrator/leases/.last_now
scripts/lease acquire R92 --session sessC 2>/dev/null && bad "backward clock permitted acquire" \
  || ok "backward clock refuses acquire (monotonic floor)"
echo 0 > .orchestrator/leases/.last_now

# corruption fails closed
sed -i 's/^generation=.*/generation=zzz/' .orchestrator/leases/R90.lease
scripts/lease acquire R90 --session sessB 2>/dev/null && bad "corrupt generation permitted acquire" \
  || ok "corrupt generation fails closed"
sed -i 's/^generation=.*/generation=1/' .orchestrator/leases/R90.lease
sed -i 's/^expiry=.*/expiry=soon/' .orchestrator/leases/R90.lease
scripts/lease acquire R90 --session sessB 2>/dev/null && bad "malformed expiry permitted takeover" \
  || ok "malformed expiry fences takeover (counts as live)"
sed -i "s/^expiry=.*/expiry=$(( $(date +%s) + 60 ))/" .orchestrator/leases/R90.lease

# dead-letter fencing
mkdir -p .orchestrator/deadletters && : > .orchestrator/deadletters/R92
scripts/lease acquire R92 --session sessD 2>/dev/null; [ $? -eq 3 ] \
  && ok "a dead-lettered row refuses acquisition (rc 3)" || bad "dead-letter did not fence acquire"
rm .orchestrator/deadletters/R92

# ---- two-session BARRIER race: exactly one winner -------------------------------------------------
( until [ -e go ]; do :; done; scripts/lease acquire R92 --session raceA --ttl 60 > raceA 2>/dev/null ) &
( until [ -e go ]; do :; done; scripts/lease acquire R92 --session raceB --ttl 60 > raceB 2>/dev/null ) &
sleep 0.2; : > go; wait
winners=0
[ -s raceA ] && winners=$((winners+1))
[ -s raceB ] && winners=$((winners+1))
[ "$winners" -eq 1 ] && ok "two-session simultaneous race: exactly one lease winner" \
  || bad "race produced $winners winners"

# ---- expiry drill: authority dies WITH the lease, then a fresh session takes over ------------------
g_old=$(scripts/lease acquire R91 --session sessOld --ttl 1); sleep 2
# BEFORE any takeover: the expired owner has already lost every authority operation
scripts/lease renew R91 --session sessOld --generation "$g_old" --ttl 60 2>/dev/null \
  && bad "an EXPIRED owner renewed itself before takeover" \
  || ok "an EXPIRED owner cannot renew itself back to life (re-acquire is the only path)"
scripts/lease release R91 --session sessOld --generation "$g_old" 2>/dev/null \
  && bad "an EXPIRED owner released before takeover" || ok "an EXPIRED owner cannot release"
scripts/lease check R91 --session sessOld --generation "$g_old" 2>/dev/null \
  && bad "check matched an expired owner" || ok "the authority probe refuses an expired owner"
g_new=$(scripts/lease acquire R91 --session sessNew --ttl 60)
[ "$g_new" -gt "$g_old" ] && ok "expired lease: fresh session acquires the next generation" \
  || bad "takeover did not raise the generation"
scripts/lease renew R91 --session sessOld --generation "$g_old" --ttl 60 2>/dev/null \
  && bad "stale session renewed" || ok "stale session refused: renew"
scripts/lease release R91 --session sessOld --generation "$g_old" 2>/dev/null \
  && bad "stale session released" || ok "stale session refused: release"

# ---- intake fence: close/observe on a LIVE-leased row require the owning tuple --------------------
if scripts/intake close R90 "evidence text" 2>/dev/null; then
  bad "close succeeded without the owning session (fence absent)"
else ok "close refuses without the owning session"; fi
if ORCH_SESSION_ID=sessX ORCH_LEASE_GENERATION=1 scripts/intake close R90 "evidence text" 2>/dev/null; then
  bad "close accepted a NON-owning session"
else ok "close refuses a non-owning session"; fi
ORCH_SESSION_ID=sessA ORCH_LEASE_GENERATION=1 scripts/intake close R90 "evidence text" >/dev/null \
  && ok "the owning session+generation closes the row" || bad "owner close failed"
# released lease: the fence lifts (manual mode resumes)
scripts/lease release R91 --session sessNew --generation "$g_new"
scripts/intake close R91 "evidence text" >/dev/null 2>&1 \
  && ok "a RELEASED lease no longer fences (manual mode resumes)" \
  || bad "released lease still fenced close"
# expired lease: the fence lifts too
printf '| R93 | 07-16 | short row | — | — | open | DONE WHEN: x |\n' >> .orchestrator/REQUEST-LEDGER.md
scripts/lease acquire R93 --session sessT --ttl 1 >/dev/null; sleep 2
scripts/intake close R93 "evidence text" >/dev/null 2>&1 \
  && ok "an EXPIRED lease no longer fences" || bad "expired lease still fenced close"
# malformed lease file fails closed at the fence
g92=$(scripts/lease acquire R92 --session sessM --ttl 60) || true
sed -i 's/^expiry=.*/expiry=bogus/' .orchestrator/leases/R92.lease
scripts/intake close R92 "evidence text" 2>/dev/null \
  && bad "malformed lease did not fail the fence closed" \
  || ok "a malformed lease fails the intake fence closed"

cd - >/dev/null

# ---- dispatcher binding (unit level, patched roots) ------------------------------------------------
PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ -x "$PY" ] && "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
"$PY" - <<'PY' || fails=1
import importlib.util, json, os, pathlib, sys, tempfile, time

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod

d = load("d", "scripts/dispatch.py")
oks, fails = [], []
def check(name, cond):
    print(("  ok: " if cond else "  FAIL: ") + name)
    if not cond: fails.append(name)

work = pathlib.Path(tempfile.mkdtemp())
d.LEASES = work / "leases"; d.LEASES.mkdir()

def write_lease(row, gen, sess, exp):
    (d.LEASES / f"{row}.lease").write_text(
        f"row={row}\ngeneration={gen}\nsession={sess}\nexpiry={exp}\n")

def try_die(fn, *a):
    try:
        fn(*a); return 0
    except SystemExit as e:
        return e.code

# no intake_row -> no fencing, empty tuple
check("approval without intake_row binds nothing", d.resolve_lease_binding({}) == {})
# row without a lease refuses
os.environ.update(ORCH_SESSION_ID="sessA", ORCH_LEASE_GENERATION="1")
check("intake_row without a lease refuses launch (exit 6)",
      try_die(d.resolve_lease_binding, {"intake_row": "R90"}) == 6)
# live matching lease freezes the tuple
write_lease("R90", 1, "sessA", int(time.time()) + 60)
check("a held live lease freezes {row, generation, session}",
      d.resolve_lease_binding({"intake_row": "R90"})
      == {"intake_row": "R90", "lease_generation": "1", "lease_session": "sessA"})
# mismatched session, wrong generation, expired lease all refuse
os.environ["ORCH_SESSION_ID"] = "sessB"
check("a non-owning session cannot launch against the row",
      try_die(d.resolve_lease_binding, {"intake_row": "R90"}) == 6)
os.environ.update(ORCH_SESSION_ID="sessA", ORCH_LEASE_GENERATION="9")
check("a wrong generation cannot launch", try_die(d.resolve_lease_binding, {"intake_row": "R90"}) == 6)
os.environ["ORCH_LEASE_GENERATION"] = "1"
write_lease("R90", 1, "sessA", int(time.time()) - 5)
check("an expired lease cannot launch (acquire afresh first)",
      try_die(d.resolve_lease_binding, {"intake_row": "R90"}) == 6)

# stale-authority checks on the frozen tuple
write_lease("R90", 1, "sessA", int(time.time()) + 60)
lc = {"intake_row": "R90", "lease_generation": "1", "lease_session": "sessA"}
check("a matching frozen tuple is not stale", d.lease_tuple_stale(lc) is None)
write_lease("R90", 2, "sessB", int(time.time()) + 60)
check("a superseded lease makes the frozen tuple stale (refusal string)",
      "stale authority" in (d.lease_tuple_stale(lc) or ""))
write_lease("R90", 1, "sessA", int(time.time()) - 5)
check("an EXPIRED lease is stale authority even for the tuple's own session",
      "expired" in (d.lease_tuple_stale(lc) or ""))
(d.LEASES / "R90.lease").unlink()
check("a vanished lease is stale (fail closed)", "vanished" in (d.lease_tuple_stale(lc) or ""))
check("an unbound attempt is never stale", d.lease_tuple_stale({}) is None)

# call sites: continue and merge consult the frozen tuple (source-pinned like sibling suites)
import inspect
check("dispatch continue refuses stale lease authority",
      "lease_tuple_stale" in inspect.getsource(d.cmd_continue))
check("dispatch merge refuses stale lease authority",
      "lease_tuple_stale" in inspect.getsource(d.cmd_merge))
check("launch freezes the tuple via resolve_lease_binding",
      "resolve_lease_binding" in inspect.getsource(d.cmd_launch))

sys.exit(1 if fails else 0)
PY
else
  echo "  note: dispatcher binding checks need .venv (box); shell-level checks above ran"
fi

if [ "$fails" -ne 0 ]; then echo "FAIL lease.sh"; exit 1; fi
echo "PASS lease.sh"
