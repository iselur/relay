#!/usr/bin/env bash
# Production-path tests for the kimi ACP transport (PLAN-009 slice 2):
# complete isolated_cmd/Popen call (all kwargs: private_network, binds, cwd,
# deadline), prompt delivery via drive() (never in argv), response correlation,
# fail-closed protocol handling, and alias validation.
# Pure logic — no sudo, no network, no kimi install. Same venv-skip contract
# as tests/dispatch_worker_adapter.sh.
set -uo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP kimi_acp_transport.sh: .venv/pyyaml/jsonschema absent"
  exit 77
fi

"$PY" - <<'PY'
import contextlib, hashlib, importlib.util, pathlib, subprocess, sys, tempfile, types

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod  = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod
d = load("d", "scripts/dispatch.py")

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

# ---- fixtures ----------------------------------------------------------------
snap = b"id: SPEC-000\n"
att  = pathlib.Path(tempfile.mkdtemp())
(att / "raw").mkdir(); (att / "spec-snapshot.yaml").write_bytes(snap)
DIGEST      = hashlib.sha256(snap).hexdigest()
ALIAS       = "kimi-code/k3"
WTE         = pathlib.Path("/nonexistent-wt")
FAKE_PREFIX = ["/opt/kimi/kimi"]; FAKE_BINDS = [("/real/kimi", "/opt/kimi/kimi")]
lc_base = {"spec_digest": DIGEST, "isolation": True, "deadline_ts": 4102444800.0,
           "worker_vendor": "kimi", "reviewer_vendor": "claude", "worker_model": "kimi-k3",
           "worker_effort": "max", "worker_unit": "kimi-SPEC-000-1",
           "cli_aliases": {"kimi-k3": ALIAS}}

class _Stop(Exception): pass
_rec = {}
def _finish(status, error_class, **kw):
    _rec.update({"status": status, "error_class": error_class, **kw}); raise _Stop()
class _FakeProc:
    stdin = None; stdout = None; returncode = 0
    def wait(self, timeout=None): return 0
    def poll(self): return 0
    def kill(self): pass

@contextlib.contextmanager
def patched(lc_extra=None, prompt_text=None, drive_res=None, grade_stub=None):
    """Swap out kimi_acp, isolated_cmd, Popen, and optional prompt/grade.
    Yields (lc, cmd_cap, drv_cap, pop_cap) — all populated by the stubs."""
    lc = {**lc_base, **(lc_extra or {})}
    cmd_cap = {}; drv_cap = {}; pop_cap = {}
    dr = {"effective_status": 1, "proc_exit": 0, "stop_reason": None, "failure": "eof",
          "detail": "", "final_message": "ACP-MSG", "model_value": ALIAS,
          "stage": "session/prompt", **(drive_res or {})}
    saved      = {k: getattr(d, k) for k in
                  ("worker_kimi_runtime", "isolated_cmd", "_grade_phase", "worker_prompt_text")}
    saved_Popen = d.subprocess.Popen; saved_acp = d.kimi_acp

    def _fake_icmd(unit, argv, cwd, rw_paths, private_network, ceiling_s,
                   binds=None, env_extra=None, slice_name=None):
        cmd_cap.update({"unit": unit, "argv": list(argv), "cwd": cwd,
                        "rw_paths": list(rw_paths), "private_network": private_network,
                        "ceiling_s": ceiling_s, "binds": binds,
                        "env_extra": env_extra, "slice_name": slice_name})
        return ["echo", "fake"]
    def _fake_Popen(cmd, **kw):
        pop_cap.update({"cmd": list(cmd), **kw}); return _FakeProc()
    fake_acp = types.ModuleType("kimi_acp_stub")
    def _fake_drive(proc, *, prompt_text, cwd, model_alias, frame_sink, deadline_s, **kw):
        drv_cap.update({"prompt_text": prompt_text, "model_alias": model_alias,
                        "deadline_s": deadline_s}); return dr
    fake_acp.drive = _fake_drive

    d.worker_kimi_runtime = lambda: (FAKE_PREFIX, FAKE_BINDS, "/real/kimi")
    d.isolated_cmd = _fake_icmd; d.subprocess.Popen = _fake_Popen; d.kimi_acp = fake_acp
    if prompt_text is not None: d.worker_prompt_text = lambda *_: prompt_text
    if grade_stub  is not None: d._grade_phase = grade_stub
    try:
        yield lc, cmd_cap, drv_cap, pop_cap
    finally:
        for k, v in saved.items(): setattr(d, k, v)
        d.subprocess.Popen = saved_Popen; d.kimi_acp = saved_acp

def run(lc_extra=None, prompt_text=None, drive_res=None, grade_stub=None):
    with patched(lc_extra, prompt_text, drive_res, grade_stub) as (lc, c, drv, pop):
        _rec.clear(); rec = {}
        try:   d._run_pipeline("SPEC-000-1", "SPEC-000", 1, att, lc, WTE, att/"raw", _finish)
        except _Stop:          rec = dict(_rec)
        except Exception as e: rec = {"exception": str(e)}
    return rec, c, drv, pop

# ---- kimi_acp present at import ----------------------------------------------
check("kimi_acp present at dispatch import", hasattr(d, "kimi_acp") and d.kimi_acp is not None)
check("d.kimi_acp.drive is callable",        callable(getattr(d.kimi_acp, "drive", None)))

# ---- happy path: complete isolated_cmd call, Popen kwargs, driver, grading ---
grade_cap = {}
def _grade_cap(aid, sid, n, ad, lc, wt, raw, fin, wa, worker_exit, se, last_message):
    grade_cap.update({"worker_exit": worker_exit, "last_message": last_message}); raise _Stop()

rec, cmd, drv, pop = run(
    prompt_text="do the thing",
    drive_res={"effective_status": 0, "proc_exit": 0, "stop_reason": "end_turn",
               "failure": None, "final_message": "CORR-FINAL"},
    grade_stub=_grade_cap)
# isolated_cmd call
check("argv is [prefix--, 'acp']",              cmd.get("argv") == [*FAKE_PREFIX, "acp"])
check("unit matches lc worker_unit",            cmd.get("unit") == lc_base["worker_unit"])
check("slice_name matches attempt_slice(id)",   cmd.get("slice_name") == d.attempt_slice("SPEC-000-1"))
check("private_network=False",                  cmd.get("private_network") is False)
check("binds matches kimi runtime binds",       cmd.get("binds") == FAKE_BINDS)
check("cwd is worktree path",                   cmd.get("cwd") == str(WTE))
check("ceiling_s is a positive number",
      isinstance(cmd.get("ceiling_s"), (int, float)) and cmd["ceiling_s"] > 0)
# Popen call
check("Popen cmd is isolated_cmd return value", pop.get("cmd") == ["echo", "fake"])
check("Popen stdin=PIPE",                       pop.get("stdin") is subprocess.PIPE)
check("Popen stdout=PIPE",                      pop.get("stdout") is subprocess.PIPE)
check("Popen stderr is a file object (not DEVNULL/PIPE/None)",
      hasattr(pop.get("stderr"), "write"))
# driver inputs
check("prompt absent from argv",                "do the thing" not in cmd.get("argv", []))
check("prompt delivered to drive() verbatim",   drv.get("prompt_text") == "do the thing")
check("model alias delivered to drive()",       drv.get("model_alias") == ALIAS)
# grading
check("final_message from drive() reaches grading", grade_cap.get("last_message") == "CORR-FINAL")
check("effective_status=0 reaches grading as worker_exit=0", grade_cap.get("worker_exit") == 0)

# ---- prompt-size table -------------------------------------------------------
for label, prompt in [("small", "do the thing"), ("oversized (140 KB)", "x" * 140_000)]:
    rec, cmd, drv, _ = run(prompt_text=prompt)
    check(f"{label}: prompt delivered to drive() intact", drv.get("prompt_text") == prompt)
    check(f"{label}: prompt absent from argv",
          not any(prompt in str(a) for a in cmd.get("argv", [])))
check("oversized prompt exceeds MAX_ARG_STRLEN (131072 bytes)",
      len(("x" * 140_000).encode()) > 131_072)

# ---- alias validation table --------------------------------------------------
for label, aliases in [("missing", {}),
                        ("identity", {"kimi-k3": "kimi-k3"}),
                        ("non-string", {"kimi-k3": 7})]:
    rec, *_ = run(lc_extra={"cli_aliases": aliases})
    check(f"alias {label} -> error_launch",
          rec.get("status") == "error_launch" and rec.get("error_class") == d.ERR_LAUNCH)

# ---- protocol failure table (fail-closed) ------------------------------------
for label, failure, px in [
    ("C1 zero-exit incomplete (eof, proc_exit=0)", "eof",            0),
    ("malformed frame",                            "malformed_frame", 1),
    ("jsonrpc error",                              "jsonrpc_error",   1),
]:
    rec, *_ = run(drive_res={"effective_status": 1, "proc_exit": px,
                              "stop_reason": None, "failure": failure})
    check(f"fail-closed {label} -> failed_worker_error",
          rec.get("status") == "failed_worker_error")
    check(f"fail-closed {label} -> TERMINAL",
          rec.get("status") in d.TERMINAL)

sys.exit(0 if not fails else 1)
PY

if [ $? -eq 0 ]; then echo "PASS kimi_acp_transport.sh"; exit 0
else echo "FAIL kimi_acp_transport.sh"; exit 1; fi
