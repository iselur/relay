#!/usr/bin/env bash
# worker_codex_runtime() resolution + vetting (round-1 review of the portability fix): the npm
# and native-ELF layouts must resolve; an npm shim script, a non-executable file, and a
# group/world-writable binary must be REJECTED. Pure logic — no sudo, runs in CI. Rejection is
# asserted as "our planted candidate was not chosen" (the box's own real install, if any, may
# still resolve — that is correct behaviour, not a test failure).
set -uo pipefail
cd "$(dirname "$0")/.."
PY="${ORCH_TEST_PY:-.venv/bin/python}"
[ -x "$PY" ] || { echo "SKIP codex_runtime.sh: trusted Python runtime absent"; exit 77; }

if "$PY" - <<'PY'
import importlib.util, os, pathlib, shutil, sys, tempfile
s = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(s); s.loader.exec_module(d)

ELF = b"\x7fELF" + b"\x00" * 60
fails = []

def probe(setup):
    """Run worker_codex_runtime with OPERATOR_HOME pointed at a fresh fake home; return
    (result, home). setup(home) plants this case's candidate files."""
    home = pathlib.Path(tempfile.mkdtemp())
    setup(home)
    d.OPERATOR_HOME = home
    d.CODEX_PKG = home / ".local/lib/node_modules/@openai/codex"
    return d.worker_codex_runtime(), home

def chose_ours(got, home):
    return got is not None and str(got[2]).startswith(str(home))

def case(name, setup, expect_ours):
    got, home = probe(setup)
    if chose_ours(got, home) != expect_ours:
        fails.append(f"{name}: expected ours={expect_ours}, got {got}")
    else:
        print(f"  ok: {name}")
    shutil.rmtree(home, ignore_errors=True)

def native(home, mode=0o755, body=ELF, name=".codex/bin/codex"):
    p = home / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(body); p.chmod(mode)
    return p

# 1. native ELF, executable, owner-only-writable -> accepted
case("native ELF accepted", lambda h: native(h), True)
# 2. npm shim (node script) planted as the native candidate -> rejected (needs node, not standalone)
case("npm shim rejected", lambda h: native(h, body=b"#!/usr/bin/env node\nrequire('x')\n"), False)
# 3. non-executable ELF -> rejected
case("non-executable ELF rejected", lambda h: native(h, mode=0o644), False)
# 4. world-writable ELF -> rejected (worker-swappable mount source); group-writable is accepted
#    ONLY when the file's group is verifiably private to this user (_group_is_private), so the
#    expectation is computed per-box, not assumed
case("world-writable ELF rejected", lambda h: native(h, mode=0o777), False)
got, home = probe(lambda h: native(h, mode=0o775))
private = d._group_is_private((home / ".codex/bin/codex").stat().st_gid)
if chose_ours(got, home) != private:
    fails.append(f"group-writable ELF: accepted={chose_ours(got, home)} but group private={private}")
else:
    print(f"  ok: group-writable ELF {'accepted' if private else 'rejected'} (group private={private})")
shutil.rmtree(home, ignore_errors=True)
# 5. symlinked candidate -> accepted via its resolved real path
def symlinked(h):
    real = native(h, name=".codex/versions/1.0/codex")
    (h / ".codex/bin").mkdir(parents=True, exist_ok=True)
    os.symlink(real, h / ".codex/bin/codex")
case("symlink resolved and accepted", symlinked, True)
got, home = probe(symlinked)
if got and "versions/1.0" not in str(got[2]):
    fails.append(f"symlink entry not resolved to real path: {got[2]}")
shutil.rmtree(home, ignore_errors=True)
# 6. npm layout (codex.js + system node) -> accepted, argv runs node (only testable where
#    /usr/bin/node exists; the vetting logic is identical either way)
if pathlib.Path("/usr/bin/node").exists():
    def npm(h):
        pkg = h / ".local/lib/node_modules/@openai/codex/bin"
        pkg.mkdir(parents=True)
        (pkg / "codex.js").write_text("// entry\n")
    got, home = probe(npm)
    if not (chose_ours(got, home) and got[0][0] == "/usr/bin/node"):
        fails.append(f"npm layout not resolved via node: {got}")
    else:
        print("  ok: npm layout accepted via system node")
    shutil.rmtree(home, ignore_errors=True)
else:
    print("  skip: npm-layout case (/usr/bin/node absent; native cases above still ran)")

# 7. pins must move when ANY pinned byte moves: entry-file hash and whole-tree hash (the npm
#    package DIRECTORY is what gets mounted — round-2 review: entry-only hashing left the
#    vendor binaries inside the mount unpinned)
home = pathlib.Path(tempfile.mkdtemp())
pkg = home / "pkg"; (pkg / "vendor").mkdir(parents=True)
(pkg / "bin").mkdir(); (pkg / "bin/codex.js").write_text("// entry\n")
(pkg / "vendor/codex-native").write_bytes(ELF)
f1, t1 = d.runtime_fingerprint(pkg / "bin/codex.js"), d._tree_fingerprint(pkg)
(pkg / "vendor/codex-native").write_bytes(ELF + b"tampered")
f2, t2 = d.runtime_fingerprint(pkg / "bin/codex.js"), d._tree_fingerprint(pkg)
if f1 != f2:
    fails.append("entry hash moved though the entry file did not change")
elif t1 == t2:
    fails.append("tree hash did NOT move when a vendor binary inside the mount changed")
else:
    print("  ok: tree fingerprint catches vendor-binary tampering the entry hash misses")
(pkg / "bin/codex.js").write_text("// tampered entry\n")
if d.runtime_fingerprint(pkg / "bin/codex.js") == f1:
    fails.append("entry hash did not move on entry change")
else:
    print("  ok: entry fingerprint moves on entry change")
# pin_runtime_sources covers every bind source plus the host interpreter
if pathlib.Path("/usr/bin/node").exists():
    pins = d.pin_runtime_sources(["/usr/bin/node", "/opt/codex/bin/codex.js"],
                                 [(str(pkg), "/opt/codex")])
    if "/usr/bin/node" not in pins or str(pkg) not in pins:
        fails.append(f"pin_runtime_sources missed a source: {sorted(pins)}")
    else:
        print("  ok: host interpreter pinned alongside bind sources")
shutil.rmtree(home, ignore_errors=True)

# 8. whole-tree trust (round-3): a package tree with a clean vendor binary is trusted; a
#    world-writable vendor file, or a symlink escaping the tree, makes the WHOLE tree untrusted.
def mkpkg(home):
    pkg = home / ".local/lib/node_modules/@openai/codex"
    (pkg / "bin").mkdir(parents=True); (pkg / "vendor").mkdir()
    (pkg / "bin/codex.js").write_text("// entry\n")
    (pkg / "vendor/codex-native").write_bytes(ELF); (pkg / "vendor/codex-native").chmod(0o755)
    return pkg
home = pathlib.Path(tempfile.mkdtemp()); pkg = mkpkg(home)
if not d.trusted_runtime_tree(pkg):
    fails.append("clean package tree rejected")
else:
    print("  ok: clean package tree trusted")
(pkg / "vendor/codex-native").chmod(0o757)   # world-writable vendor binary
if d.trusted_runtime_tree(pkg):
    fails.append("world-writable vendor binary did NOT untrust the tree")
else:
    print("  ok: world-writable vendor binary untrusts the tree")
shutil.rmtree(home, ignore_errors=True)
home = pathlib.Path(tempfile.mkdtemp()); pkg = mkpkg(home)
(home / "outside-secret").write_text("x")
os.symlink(home / "outside-secret", pkg / "vendor/escape")   # symlink escaping the mounted tree
if d.trusted_runtime_tree(pkg):
    fails.append("escaping symlink did NOT untrust the tree")
else:
    print("  ok: escaping symlink untrusts the tree")
shutil.rmtree(home, ignore_errors=True)
# 9. an ownership/mode flip on a vendor file moves the tree hash even with identical bytes
home = pathlib.Path(tempfile.mkdtemp()); pkg = mkpkg(home)
th1 = d._tree_fingerprint(pkg)
(pkg / "vendor/codex-native").chmod(0o775)
th2 = d._tree_fingerprint(pkg)
if th1 == th2:
    fails.append("tree hash unchanged after a vendor-file mode flip (bytes identical)")
else:
    print("  ok: tree hash moves on a mode flip with identical bytes")
shutil.rmtree(home, ignore_errors=True)

# 10. round-4: a named POSIX ACL on a vendor file untrusts the tree (write granted invisibly to a
#     mode check). Uses setfacl + `nobody`; skips if either is unavailable.
import shutil as _sh, subprocess
home = pathlib.Path(tempfile.mkdtemp()); pkg = mkpkg(home)
if _sh.which("setfacl") and subprocess.run(["id", "nobody"], capture_output=True).returncode == 0:
    if subprocess.run(["setfacl", "-m", "u:nobody:rwx", str(pkg / "vendor/codex-native")],
                      capture_output=True).returncode == 0:
        if d.trusted_runtime_tree(pkg):
            fails.append("named ACL granting nobody:rwx did NOT untrust the tree")
        else:
            print("  ok: named ACL untrusts the tree")
    else:
        print("  skip: setfacl failed (no ACL support on this fs)")
else:
    print("  skip: setfacl or nobody absent")
shutil.rmtree(home, ignore_errors=True)

# 11. round-4: a NON-sticky world-writable ancestor untrusts the source (rename-parent attack),
#     while a sticky world-writable ancestor (like /tmp) does NOT — sticky blocks the rename.
base = pathlib.Path(tempfile.mkdtemp())
mid = base / "mid"; mid.mkdir(); pkg = mkpkg(mid)
th_before = d.trusted_runtime_tree(pkg)
mid.chmod(0o777)   # world-writable, NO sticky -> attacker can replace pkg
if not th_before:
    fails.append("baseline: clean nested tree rejected before chmod")
elif d.trusted_runtime_tree(pkg):
    fails.append("non-sticky world-writable parent did NOT untrust the source")
else:
    print("  ok: non-sticky world-writable parent untrusts the source")
mid.chmod(0o1777)  # now sticky -> safe again
if not d.trusted_runtime_tree(pkg):
    fails.append("sticky world-writable parent wrongly untrusts the source")
else:
    print("  ok: sticky world-writable parent (like /tmp) is accepted")
shutil.rmtree(base, ignore_errors=True)

# 12. round-5: the recorded npm bind SOURCE is the RESOLVED real path, never the unresolved
#     (possibly symlinked) string that could be repointed before systemd mounts it.
if pathlib.Path("/usr/bin/node").exists():
    home = pathlib.Path(tempfile.mkdtemp())
    realpkg = home / "real/node_modules/@openai/codex"
    (realpkg / "bin").mkdir(parents=True); (realpkg / "bin/codex.js").write_text("// e\n")
    link = home / "link"; os.symlink(home / "real/node_modules/@openai/codex", link)
    d.CODEX_PKG = link                       # reached via a symlink
    d.OPERATOR_HOME = home
    rt = d.worker_codex_runtime()
    if not rt:
        fails.append("symlinked npm package did not resolve at all")
    else:
        src = rt[1][0][0]
        if pathlib.Path(src).is_symlink() or "/link" in src:
            fails.append(f"npm bind source is the UNRESOLVED path: {src}")
        elif pathlib.Path(src).resolve() != realpkg.resolve():
            fails.append(f"npm bind source {src} != resolved real pkg")
        else:
            print("  ok: npm bind source is the resolved real path (not the symlink)")
    shutil.rmtree(home, ignore_errors=True)
else:
    print("  skip: resolved-bind-source case (/usr/bin/node absent)")

for f in fails:
    print(f"  FAIL {f}")
sys.exit(1 if fails else 0)
PY
then echo "PASS codex_runtime.sh"; else echo "FAIL codex_runtime.sh"; exit 1; fi
