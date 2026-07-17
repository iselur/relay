#!/usr/bin/env bash
# worker_kimi_runtime() resolution + vetting (kimi brief, slice 3): the native single-ELF
# layout must resolve from the operator's install locations; a shim script, a non-executable
# file, and a group/world-writable binary must be REJECTED — kimi has NO npm layout (probe A,
# .orchestrator/evidence/kimi-probes.md). Also proves resolver selection follows the frozen
# worker vendor and pin_runtime_sources recognizes bind DESTINATIONS generally (the previous
# /opt/codex-literal check would have probed kimi's /opt/kimi/kimi as a nonexistent host
# path) while codex native and npm pinning stay unchanged. Pure logic — no sudo. Rejection is
# asserted as "our planted candidate was not chosen" (the box's own real install, if any, may
# still resolve — that is correct behaviour, not a test failure).
set -uo pipefail
cd "$(dirname "$0")/.."
PY="${ORCH_TEST_PY:-.venv/bin/python}"
[ -x "$PY" ] || { echo "SKIP kimi_runtime.sh: trusted Python runtime absent"; exit 77; }

if "$PY" - <<'PY'
import importlib.util, os, pathlib, shutil, sys, tempfile
s = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(s); s.loader.exec_module(d)

ELF = b"\x7fELF" + b"\x00" * 60
fails = []

def probe(setup):
    """Run worker_kimi_runtime with OPERATOR_HOME pointed at a fresh fake home; return
    (result, home). setup(home) plants this case's candidate files."""
    home = pathlib.Path(tempfile.mkdtemp())
    setup(home)
    d.OPERATOR_HOME = home
    return d.worker_kimi_runtime(), home

def chose_ours(got, home):
    return got is not None and str(got[2]).startswith(str(home))

def case(name, setup, expect_ours):
    got, home = probe(setup)
    if chose_ours(got, home) != expect_ours:
        fails.append(f"{name}: expected ours={expect_ours}, got {got}")
    else:
        print(f"  ok: {name}")
    shutil.rmtree(home, ignore_errors=True)

def native(home, mode=0o755, body=ELF, name=".kimi-code/bin/kimi"):
    p = home / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(body); p.chmod(mode)
    return p

# 1. native ELF, executable, owner-only-writable -> accepted
case("native ELF accepted", lambda h: native(h), True)
# 2. a shim script planted as the candidate -> rejected (kimi is native-single-ELF only)
case("shim script rejected", lambda h: native(h, body=b"#!/bin/sh\nexec kimi-real\n"), False)
# 3. non-executable ELF -> rejected
case("non-executable ELF rejected", lambda h: native(h, mode=0o644), False)
# 4. world-writable ELF -> rejected; group-writable accepted ONLY when the group is
#    verifiably private to this user (_group_is_private), computed per-box like codex
case("world-writable ELF rejected", lambda h: native(h, mode=0o777), False)
got, home = probe(lambda h: native(h, mode=0o775))
private = d._group_is_private((home / ".kimi-code/bin/kimi").stat().st_gid)
if chose_ours(got, home) != private:
    fails.append(f"group-writable ELF: accepted={chose_ours(got, home)} but group private={private}")
else:
    print(f"  ok: group-writable ELF {'accepted' if private else 'rejected'} (group private={private})")
shutil.rmtree(home, ignore_errors=True)
# 5. symlinked candidate -> accepted via its resolved real path; argv execs the bind
#    DESTINATION and the bind SOURCE is the resolved real path (never the repointable symlink)
def symlinked(h):
    real = native(h, name=".kimi-code/versions/0.26.0/kimi")
    (h / ".kimi-code/bin").mkdir(parents=True, exist_ok=True)
    os.symlink(real, h / ".kimi-code/bin/kimi")
case("symlink resolved and accepted", symlinked, True)
got, home = probe(symlinked)
if got:
    argv, binds, entry = got
    if "versions/0.26.0" not in str(entry):
        fails.append(f"symlink entry not resolved to real path: {entry}")
    elif argv != ["/opt/kimi/kimi"] or binds != [(str(entry), "/opt/kimi/kimi")]:
        fails.append(f"kimi argv/bind shape wrong: {argv} {binds}")
    else:
        print("  ok: argv execs /opt/kimi/kimi; bind source is the resolved real path")
shutil.rmtree(home, ignore_errors=True)

# 5b. a named POSIX ACL on the candidate rejects it (write granted invisibly to a mode
#     check) — mirrors codex_runtime.sh case 10; skips if setfacl/nobody unavailable.
import subprocess
home = pathlib.Path(tempfile.mkdtemp()); cand = native(home)
if shutil.which("setfacl") and subprocess.run(["id", "nobody"],
                                              capture_output=True).returncode == 0:
    if subprocess.run(["setfacl", "-m", "u:nobody:rwx", str(cand)],
                      capture_output=True).returncode == 0:
        d.OPERATOR_HOME = home
        got = d.worker_kimi_runtime()
        if chose_ours(got, home):
            fails.append("named ACL granting nobody:rwx did NOT reject the kimi candidate")
        else:
            print("  ok: named ACL rejects the candidate")
    else:
        print("  skip: setfacl failed (no ACL support on this fs)")
else:
    print("  skip: setfacl or nobody absent")
shutil.rmtree(home, ignore_errors=True)
# 5c. unsafe ancestry: a NON-sticky world-writable ancestor rejects the candidate
#     (rename-parent attack); sticky (like /tmp) is accepted — mirrors codex case 11.
base = pathlib.Path(tempfile.mkdtemp())
mid = base / "mid"; mid.mkdir()
cand = native(mid)
d.OPERATOR_HOME = mid
ancestry_before = chose_ours(d.worker_kimi_runtime(), mid)
mid.chmod(0o777)   # world-writable, NO sticky
ancestry_open = chose_ours(d.worker_kimi_runtime(), mid)
mid.chmod(0o1777)  # sticky -> safe again
ancestry_sticky = chose_ours(d.worker_kimi_runtime(), mid)
if not ancestry_before:
    fails.append("baseline: clean nested candidate rejected before chmod")
elif ancestry_open:
    fails.append("non-sticky world-writable parent did NOT reject the candidate")
elif not ancestry_sticky:
    fails.append("sticky world-writable parent wrongly rejects the candidate")
else:
    print("  ok: non-sticky world-writable ancestor rejects; sticky accepted")
shutil.rmtree(base, ignore_errors=True)

# 6. resolver selection follows the FROZEN worker vendor (launch probe + legacy fallback)
if d.worker_runtime_resolver("kimi") is not d.worker_kimi_runtime:
    fails.append("worker_runtime_resolver('kimi') is not worker_kimi_runtime")
elif d.worker_runtime_resolver("codex") is not d.worker_codex_runtime:
    fails.append("worker_runtime_resolver('codex') is not worker_codex_runtime")
else:
    print("  ok: runtime resolver selection follows the frozen worker vendor")

# 7. pin_runtime_sources recognizes bind destinations generally: kimi's argv[0] is the bind
#    DESTINATION (not a host path) so only the SOURCE is pinned; codex native and npm keep
#    their pre-slice-3 pin sets exactly.
home = pathlib.Path(tempfile.mkdtemp())
kbin = home / "kimi"; kbin.write_bytes(ELF)
pins = d.pin_runtime_sources(["/opt/kimi/kimi"], [(str(kbin), "/opt/kimi/kimi")])
if set(pins) != {str(kbin)}:
    fails.append(f"kimi pins wrong: {sorted(pins)} (argv[0] is a bind destination)")
else:
    print("  ok: kimi bind source pinned; /opt/kimi/kimi never probed as a host path")
cbin = home / "codex"; cbin.write_bytes(ELF)
pins = d.pin_runtime_sources(["/opt/codex/codex"], [(str(cbin), "/opt/codex/codex")])
if set(pins) != {str(cbin)}:
    fails.append(f"codex native pin set changed: {sorted(pins)}")
else:
    print("  ok: codex native pinning unchanged")
if pathlib.Path("/usr/bin/node").exists():
    pkg = home / "pkg"; pkg.mkdir(); (pkg / "e.js").write_text("// e\n")
    pins = d.pin_runtime_sources(["/usr/bin/node", "/opt/codex/bin/codex.js"],
                                 [(str(pkg), "/opt/codex")])
    if "/usr/bin/node" not in pins or str(pkg) not in pins:
        fails.append(f"codex npm pin set changed: {sorted(pins)}")
    else:
        print("  ok: codex npm pinning unchanged (host node still pinned)")
else:
    print("  skip: npm pin case (/usr/bin/node absent)")
# 8. round-1 review (high): degenerate destinations must NOT swallow the host pin — "" and
#    "/" cover every absolute argv[0] under a naive prefix rule; only a proper absolute
#    destination below / is recognized. A prefix COLLISION ("/opt/cod" vs /opt/codex/...)
#    must also keep the pin; a genuine ancestor destination ("/opt") legitimately covers.
hbin = home / "hostbin"; hbin.write_bytes(ELF)
for bad_dst in ("", "/", "//"):
    pins = d.pin_runtime_sources([str(hbin)], [(str(kbin), bad_dst)])
    if str(hbin) not in pins:
        fails.append(f"degenerate destination {bad_dst!r} swallowed the host argv[0] pin")
        break
else:
    print("  ok: degenerate destinations ('', '/', '//') keep the conservative host pin")
pins = d.pin_runtime_sources([str(hbin)], [(str(kbin), str(hbin)[:-3])])
if str(hbin) not in pins:
    fails.append(f"prefix collision {str(hbin)[:-3]!r} wrongly covered {hbin}")
else:
    print("  ok: prefix collision does not cover a sibling path")
pins = d.pin_runtime_sources([str(hbin)], [(str(kbin), str(hbin.parent))])
if str(hbin) in pins:
    fails.append("ancestor destination did not cover its own subtree")
else:
    print("  ok: a genuine ancestor destination covers its subtree")
shutil.rmtree(home, ignore_errors=True)

for f in fails:
    print(f"  FAIL {f}")
sys.exit(1 if fails else 0)
PY
then echo "PASS kimi_runtime.sh"; else echo "FAIL kimi_runtime.sh"; exit 1; fi
