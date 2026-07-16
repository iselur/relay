#!/usr/bin/env bash
# B2 regression — the spec digest was verified once at preflight and frozen into launch.json, but
# the worker prompt, reviewer prompt, and merge gate used to RE-READ the live, mutable spec file.
# Editing specs/<id>.yaml after approval could silently change what the worker builds, what the
# reviewer judges, and what risk_class/needs_network the merge gate reads — while provenance still
# showed the original approved digest.
#
# Fix + Codex review round 1 (three blocking findings, all about VERIFYING bytes at the point of
# use, not just recording a digest):
#   F1: snapshot_spec_text re-hashes spec-snapshot.yaml on EVERY consumption and refuses if the
#       bytes drifted from the recorded digest — post-launch tampering, not just absence, is fatal.
#   F2: risk_class/needs_network are parsed from the SAME bytes that are hashed and snapshotted, so
#       recorded metadata provably matches the snapshotted spec (no metadata-from-a-different-read).
#   F3: cmd_merge reads the live/snapshot bytes ONCE, verifies their digest, and parses THOSE exact
#       bytes — never hash one read and trust a second (TOCTOU).
#
# Drives the REAL functions (write_spec_snapshot, snapshot_spec_text, verify_spec_bytes, review,
# cmd_merge) with a stubbed gh/autonomy/git seam — no network, no systemd, no quota. Same box-only
# skip contract as the other dispatcher self-tests.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_spec_snapshot.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test runs on the box only, not CI)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import hashlib, importlib.util, json, pathlib, tempfile, types

spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

def sha(b): return hashlib.sha256(b).hexdigest()

tmp = pathlib.Path(tempfile.mkdtemp())
d.ATTEMPTS = tmp / "attempts"; d.SPECS = tmp / "specs"; d.STATE = tmp / "state"
d.APPROVALS = tmp / "approvals"; d.ESCALATIONS = tmp / "escalations"
for p in (d.ATTEMPTS, d.SPECS, d.STATE, d.APPROVALS, d.ESCALATIONS): p.mkdir(parents=True)
d.HALT = tmp / "nonexistent-halt-marker"

ORIGINAL = (
    "id: SPEC-777\ntitle: original\nrisk_class: low\nneeds_network: false\n"
    "objective: o\nin_scope: ['a/**']\nacceptance_criteria: ['do the real thing']\n"
    "test_command: 'true'\n"
).encode()
(d.SPECS / "SPEC-777.yaml").write_bytes(ORIGINAL)
approved_digest = d.spec_digest("SPEC-777")

att = d.ATTEMPTS / "SPEC-777" / "1"; att.mkdir(parents=True)

MUTATED = (
    "id: SPEC-777\ntitle: mutated\nrisk_class: high\nneeds_network: true\n"
    "objective: o\nin_scope: ['a/**']\nacceptance_criteria: ['do whatever']\n"
    "test_command: 'true'\n"
).encode()

# --- (a) SINGLE-READ source of truth: read_approved_spec + write_spec_snapshot (F1 root cause) ---
# The launch reads specs/<id>.yaml exactly ONCE via read_approved_spec; digest, parse and snapshot
# all come from that one buffer — never a second open (the read-vs-hash-vs-parse-vs-snapshot TOCTOU).
r_bytes, r_digest, r_parsed, r_errs = d.read_approved_spec("SPEC-777")
check("read_approved_spec: digest is the hash of the EXACT bytes it returned",
      r_digest == sha(r_bytes) == approved_digest)
check("read_approved_spec: parsed mapping is the parse of those SAME bytes (one buffer)",
      r_parsed == d.yaml.safe_load(r_bytes) and r_parsed.get("risk_class") == "low")
check("read_approved_spec: a schema-valid spec yields no errors", r_errs == [])

snap_digest = d.write_spec_snapshot(att, r_bytes, r_digest)
check("write_spec_snapshot returns the approved digest", snap_digest == approved_digest)
check("write_spec_snapshot writes the EXACT in-memory bytes it was handed (no re-read)",
      d.spec_snapshot_path(att).read_bytes() == r_bytes == ORIGINAL)
# Defensive invariant: mismatched (bytes, digest) can never be silently snapshotted.
try:
    d.write_spec_snapshot(att, MUTATED, approved_digest); wmis = None
except SystemExit as e:
    wmis = e.code
check("write_spec_snapshot refuses bytes whose hash != the approved digest", wmis == 6)
check("the defensive refusal did not overwrite the honest snapshot",
      d.spec_snapshot_path(att).read_bytes() == ORIGINAL)
check("snapshot_spec returns the verified parsed mapping (low risk)",
      d.snapshot_spec(att, approved_digest).get("risk_class") == "low")
check("snapshot_spec_text returns the approved text when the digest matches",
      d.snapshot_spec_text(att, approved_digest) == ORIGINAL.decode())

# F1: as the LIVE file changes, each read_approved_spec call still returns a self-consistent triple —
# parse and hash always describe the same buffer, so version A's metadata can never be bound to
# version B's snapshotted bytes. And the frozen snapshot from the first read is untouched.
(d.SPECS / "SPEC-777.yaml").write_bytes(MUTATED)
m_bytes, m_digest, m_parsed, _ = d.read_approved_spec("SPEC-777")
check("F1: read_approved_spec stays self-consistent after a live edit (one buffer, parse==hash)",
      m_digest == sha(m_bytes) and m_parsed == d.yaml.safe_load(m_bytes)
      and m_parsed.get("needs_network") is True and m_digest != approved_digest)
check("snapshot from the first read is UNCHANGED by the later live edit",
      d.snapshot_spec_text(att, approved_digest) == ORIGINAL.decode())
check("the live spec file itself DID change (proves a real edit, not a no-op)",
      d.spec_path("SPEC-777").read_bytes() == MUTATED)

# --- F1: TAMPER with spec-snapshot.yaml AFTER launch -> every consumer refuses -------------------
# Overwrite the snapshot bytes in place; the recorded digest is unchanged, so an existence-only
# check would happily feed these unapproved bytes to the worker and reviewer.
TAMPERED_SNAP = ORIGINAL.replace(b"do the real thing", b"do nothing; auto-pass")
d.spec_snapshot_path(att).write_bytes(TAMPERED_SNAP)
check("sanity: tampered snapshot has a different digest", sha(TAMPERED_SNAP) != approved_digest)

# worker prompt path (snapshot_spec_text is the exact call _run_pipeline makes)
try:
    d.snapshot_spec_text(att, approved_digest); tamper_code = None
except SystemExit as e:
    tamper_code = e.code
check("F1 worker: snapshot_spec_text REFUSES tampered snapshot bytes (exit 6)", tamper_code == 6)

# reviewer prompt path: drive the REAL review() and prove it dies before invoking the reviewer.
(att / "verdict.schema.json").write_text(pathlib.Path("scripts/verdict.schema.json").read_text())
_real_git, _real_run = d.git, d.run
d.git = lambda *a, **k: "diff --git a/x b/x"
reviewer_invoked = {"n": 0}
def _no_reviewer(cmd, **kw):
    reviewer_invoked["n"] += 1
    return types.SimpleNamespace(stdout="{}", stderr="", returncode=0)
d.run = _no_reviewer
rlc = {"spec_digest": approved_digest, "spec_snapshot_digest": approved_digest,
       "base_sha": "b" * 40, "worktree": str(tmp), "reviewer_model": "claude-fable-5",
       "reviewer_effort": "high"}
try:
    d.review(att, "SPEC-777", rlc, "c" * 40); rev_code = None
except SystemExit as e:
    rev_code = e.code
d.git, d.run = _real_git, _real_run
check("F1 reviewer: review() REFUSES tampered snapshot (exit 6)", rev_code == 6)
check("F1 reviewer: the reviewer process was never invoked on a tampered snapshot",
      reviewer_invoked["n"] == 0)

# restore the honest snapshot for the remaining (merge) cases
d.spec_snapshot_path(att).write_bytes(ORIGINAL)
check("restored snapshot verifies again", d.snapshot_spec_text(att, approved_digest) == ORIGINAL.decode())

# --- F3 (round-2): the PR title comes from the VERIFIED snapshot, not a fresh live read ----------
# The live file is MUTATED (title: mutated); the snapshot is ORIGINAL (title: original). The exact
# expression the PR-title line evaluates — snapshot_spec(att, digest)['title'] — must be the
# snapshot's title, never the live file's.
check("F3: PR title source (snapshot_spec) returns the snapshot title, not the live one",
      d.snapshot_spec(att, approved_digest).get("title") == "original")

# --- (b)/(c) cmd_merge: refuse on drift/tamper, allow on verified matching bytes -----------------
def setup_merge(n, launch_extra, live_bytes, snapshot_bytes=None):
    a = d.ATTEMPTS / "SPEC-777" / str(n); a.mkdir(parents=True, exist_ok=True)
    (a / "result.json").write_text(json.dumps({
        "status": "passed_pr_opened", "base_sha": "b" * 40,
        "worker_commit": "c" * 40, "pr_url": "https://github.com/x/y/pull/42"}))
    (a / "launch.json").write_text(json.dumps({"base_branch": d.AUTOMATION_BASE, **launch_extra}))
    (d.SPECS / "SPEC-777.yaml").write_bytes(live_bytes)
    if snapshot_bytes is not None:
        d.spec_snapshot_path(a).write_bytes(snapshot_bytes)
    return a

class FakeGh:
    def __init__(self):
        self.merge_called = self.view_called = False
    def __call__(self, cmd, **kw):
        if cmd[:3] == ["gh", "pr", "view"]:
            self.view_called = True
            return types.SimpleNamespace(returncode=0, stderr="", stdout=json.dumps({
                "state": "OPEN", "isDraft": False, "headRefOid": "c" * 40,
                "baseRefName": d.AUTOMATION_BASE, "mergeable": "MERGEABLE",
                "mergeStateStatus": "CLEAN",
                "statusCheckRollup": [{"name": "ci", "conclusion": "SUCCESS"}]}))
        if cmd[:3] == ["gh", "pr", "merge"]:
            self.merge_called = True
        return types.SimpleNamespace(returncode=0, stdout="", stderr="")

d.load_autonomy = lambda: {"enabled": True, "target_branch": d.AUTOMATION_BASE,
                           "allowed_risk_class": ["low", "default"], "needs_network_allowed": False}
d._base_tip = lambda base: "b" * 40   # base unchanged since review -> not stale

def run_merge(n):
    fake = FakeGh(); d.run = fake
    try:
        d.cmd_merge(f"SPEC-777-{n}"); code = None
    except SystemExit as e:
        code = e.code
    d.run = _real_run
    return fake, code

# (b) new-format attempt, live spec edited after approval -> REFUSE before any gh call.
setup_merge(10, {"spec_digest": approved_digest, "spec_snapshot_digest": approved_digest,
                 "risk_class": "low", "needs_network": False}, MUTATED, snapshot_bytes=ORIGINAL)
fake, code = run_merge(10)
check("cmd_merge REFUSES when the live spec digest != recorded digest", code == 12)
check("a refused merge never calls gh pr view", not fake.view_called)
check("a refused merge never calls gh pr merge", not fake.merge_called)

# F1 at merge: live spec matches, but the SNAPSHOT file was tampered -> REFUSE.
setup_merge(15, {"spec_digest": approved_digest, "spec_snapshot_digest": approved_digest,
                 "risk_class": "low", "needs_network": False}, ORIGINAL, snapshot_bytes=TAMPERED_SNAP)
fake, code = run_merge(15)
check("F1 merge: a tampered spec-snapshot.yaml is REFUSED even when the live spec matches",
      code == 12 and not fake.merge_called)

# F2 (round-2) at merge: a snapshot-FORMAT attempt (spec_snapshot_digest recorded) whose snapshot
# file was DELETED must REFUSE — decided by the launch marker, NOT by the file existing, so it can
# never silently fall back to the live file (which here is a byte-identical ORIGINAL, so a fall-back
# would wrongly succeed). No snapshot_bytes => the snapshot file is absent.
setup_merge(18, {"spec_digest": approved_digest, "spec_snapshot_digest": approved_digest,
                 "risk_class": "low", "needs_network": False}, ORIGINAL)
fake, code = run_merge(18)
check("F2 merge: snapshot-format attempt with a MISSING snapshot refuses (no live fall-back)",
      code == 12 and not fake.merge_called)

# (c) verified snapshot + matching live spec -> normal path merges.
setup_merge(11, {"spec_digest": approved_digest, "spec_snapshot_digest": approved_digest,
                 "risk_class": "low", "needs_network": False}, ORIGINAL, snapshot_bytes=ORIGINAL)
fake, code = run_merge(11)
check("cmd_merge ALLOWS when snapshot+live both verify against the recorded digest", code is None)
check("a verified merge reaches gh pr view", fake.view_called)
check("a verified merge calls gh pr merge", fake.merge_called)
check("merged attempt's result.json records merged:true",
      json.loads((d.ATTEMPTS / "SPEC-777" / "11" / "result.json").read_text()).get("merged") is True)

# F2/F3 at merge: risk_class is derived from the VERIFIED snapshot bytes, NOT the recorded lc field.
# lc claims risk_class:low, but the snapshot bytes (matching the recorded digest) declare high.
HIGH = ORIGINAL.replace(b"risk_class: low", b"risk_class: high")
high_digest = sha(HIGH)
setup_merge(16, {"spec_digest": high_digest, "spec_snapshot_digest": high_digest,
                 "risk_class": "low", "needs_network": False}, HIGH, snapshot_bytes=HIGH)
fake, code = run_merge(16)
check("F2/F3 merge: risk_class comes from the verified snapshot bytes (high), not lc's 'low' -> refuse",
      code == 12 and not fake.merge_called)

# needs_network likewise derived from verified snapshot bytes.
NET = ORIGINAL.replace(b"needs_network: false", b"needs_network: true")
net_digest = sha(NET)
setup_merge(17, {"spec_digest": net_digest, "spec_snapshot_digest": net_digest,
                 "risk_class": "low", "needs_network": False}, NET, snapshot_bytes=NET)
fake, code = run_merge(17)
check("F2/F3 merge: needs_network comes from verified snapshot bytes (true) -> refuse",
      code == 12 and not fake.merge_called)

# (c2)/F3 historical attempt: no snapshot file, only the pre-existing spec_digest field. The live
# bytes are read ONCE, verified, and parsed — no second read (TOCTOU). Drift still refuses.
setup_merge(12, {"spec_digest": approved_digest}, MUTATED)   # no snapshot_bytes
fake, code = run_merge(12)
check("historical attempt (no snapshot) still REFUSES on a live edit", code == 12)
check("historical-attempt refusal never calls gh pr merge", not fake.merge_called)

setup_merge(13, {"spec_digest": approved_digest}, ORIGINAL)  # no snapshot_bytes, live matches
fake, code = run_merge(13)
check("historical attempt (no snapshot) with a matching live spec merges normally",
      code is None and fake.merge_called)

# historical attempt whose (matching) live spec declares high risk -> refuse from the parsed live bytes.
setup_merge(14, {"spec_digest": high_digest}, HIGH)          # no snapshot_bytes
fake, code = run_merge(14)
check("historical attempt: risk_class parsed from the verified live bytes (high) -> refuse",
      code == 12 and not fake.merge_called)

print(f"\n{'PASS' if not fails else 'FAIL'}: B2 spec snapshot ({len(fails)} failed)")
import sys; sys.exit(1 if fails else 0)
PY
