#!/usr/bin/env bash
# End-state tests for the Kimi worker adapter's ACP transport and the dispatcher's
# pre-invocation Kimi policy. Pure logic — no sudo, network, or kimi install.
set -uo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP kimi_acp_transport.sh: .venv/pyyaml/jsonschema absent"
  exit 77
fi

export KIMI_TRANSPORT_INHERITED="visible-through-env-none"
"$PY" - <<'PY'
import hashlib
import importlib.util
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import textwrap
import time


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


d = load("d", "scripts/dispatch.py")
va = load("va", "scripts/vendor_adapters.py")
fails = []


def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


tmp = pathlib.Path(tempfile.mkdtemp())
stub = tmp / "acp-stub"
stub.write_text(textwrap.dedent(r'''
    #!/usr/bin/python3
    import json, os, signal, sys, time

    mode, record, inherited = sys.argv[1:4]
    open(inherited, "w").write(os.environ.get("KIMI_TRANSPORT_INHERITED", "<missing>"))
    sys.stderr.write("ACP-STDERR\n")
    sys.stderr.flush()
    if mode == "cancel":
        os.kill(os.getpid(), signal.SIGTERM)
    if mode == "timeout":
        time.sleep(30)

    def send(value):
        sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        request = json.loads(line)
        with open(record, "a") as sink:
            sink.write(json.dumps(request) + "\n")
        if mode == "protocol":
            sys.stdout.write("not-json\n")
            sys.stdout.flush()
            time.sleep(30)
        if mode == "jsonrpc":
            send({"jsonrpc": "2.0", "id": request["id"],
                  "error": {"code": -32000, "message": "stub failure"}})
            time.sleep(30)
        if mode == "eof":
            raise SystemExit(0)
        method = request["method"]
        if method == "initialize":
            answer = {"protocolVersion": 1}
        elif method == "session/new":
            answer = {"sessionId": "session-1"}
        elif method in ("session/set_model", "session/set_mode"):
            answer = {}
        else:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "session-1", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "KIMI-FINAL"}}}})
            answer = {"stopReason": "max_tokens" if mode == "stop" else "end_turn"}
        send({"jsonrpc": "2.0", "id": request["id"], "result": answer})
        if method == "session/prompt":
            raise SystemExit(7 if mode == "nonzero" else 0)
''').lstrip())
stub.chmod(0o755)

kw = va.KimiWorker()
case_number = 0


def run_adapter(mode, prompt="KIMI PROMPT", deadline=4.75):
    global case_number
    case_number += 1
    case = tmp / f"case-{case_number}-{mode}"
    case.mkdir()
    record = case / "requests.jsonl"
    inherited = case / "inherited"
    stderr_path = case / "worker-stderr.txt"
    events_path = case / "events.jsonl"
    command = [str(stub), mode, str(record), str(inherited)]
    popen_calls = []
    drive_calls = []
    original_popen = va.subprocess.Popen
    drive_code = va.kimi_acp.drive.__code__

    def capture_popen(*args, **kwargs):
        popen_calls.append((args, kwargs))
        return original_popen(*args, **kwargs)

    def trace(frame, event, arg):
        if event == "call" and frame.f_code is drive_code:
            drive_calls.append(frame.f_locals.copy())
        return trace

    with open(stderr_path, "w") as error_sink, open(events_path, "wb") as event_sink:
        envelope = va.BuildEnvelope(
            command=command, cwd="/exact/dispatcher/worktree", env=None, stdout=None,
            stderr=error_sink, deadline_seconds=deadline, isolated=True, runner=None,
            alias="kimi-code/k3", event_sink=event_sink)
        va.subprocess.Popen = capture_popen
        sys.settrace(trace)
        try:
            outcome = kw.run_build(envelope, prompt)
        finally:
            sys.settrace(None)
            va.subprocess.Popen = original_popen
    requests = ([json.loads(line) for line in record.read_text().splitlines()]
                if record.exists() else [])
    return {
        "outcome": outcome, "envelope": envelope, "requests": requests,
        "stderr": stderr_path.read_text(), "raw": case,
        "events": events_path.read_bytes(), "popen": popen_calls,
        "drive": drive_calls,
        "inherited": inherited.read_text() if inherited.exists() else None,
    }


# Real adapter + real kimi_acp + stub executable: complete transport parity.
happy = run_adapter("ok")
outcome = happy["outcome"]
envelope = happy["envelope"]
requests = happy["requests"]
check("Kimi maps effective_status without reinterpretation", outcome.exit_code == 0)
check("Kimi maps final_message without reinterpretation", outcome.last_message == "KIMI-FINAL")
check("adapter launches the complete envelope command unchanged",
      len(happy["popen"]) == 1 and happy["popen"][0][0][0] is envelope.command)
popen_kwargs = happy["popen"][0][1]
check("adapter wires child stdin/stdout to pipes",
      popen_kwargs.get("stdin") is subprocess.PIPE
      and popen_kwargs.get("stdout") is subprocess.PIPE)
check("adapter wires child stderr to the envelope sink",
      popen_kwargs.get("stderr") is envelope.stderr)
check("adapter passes env=None and inherits the harness environment",
      popen_kwargs.get("env", "absent") is None
      and happy["inherited"] == os.environ["KIMI_TRANSPORT_INHERITED"])
check("child stderr reaches the worker stderr sink", "ACP-STDERR" in happy["stderr"])
check("raw ACP frames reach the event sink", bool(happy["events"]))
new_request = next(r for r in requests if r["method"] == "session/new")
model_request = next(r for r in requests if r["method"] == "session/set_model")
prompt_request = next(r for r in requests if r["method"] == "session/prompt")
check("drive receives the exact worktree cwd", new_request["params"]["cwd"] == envelope.cwd)
check("drive receives the exact model alias",
      model_request["params"]["modelId"] == envelope.alias)
check("adapter passes the exact transport inputs to drive",
      len(happy["drive"]) == 1
      and happy["drive"][0].get("prompt_text") == "KIMI PROMPT"
      and happy["drive"][0].get("cwd") == envelope.cwd
      and happy["drive"][0].get("model_alias") == envelope.alias
      and happy["drive"][0].get("frame_sink") is envelope.event_sink
      and happy["drive"][0].get("deadline_s") == envelope.deadline_seconds)
check("prompt travels only in the ACP frame",
      prompt_request["params"]["prompt"] == [{"type": "text", "text": "KIMI PROMPT"}]
      and not any("KIMI PROMPT" in str(arg) for arg in envelope.command))

oversized_prompt = "x" * 140_000
oversized = run_adapter("ok", prompt=oversized_prompt)
oversized_request = next(r for r in oversized["requests"] if r["method"] == "session/prompt")
check("oversized prompt exceeds MAX_ARG_STRLEN", len(oversized_prompt.encode()) > 131_072)
check("oversized prompt arrives intact in its ACP frame",
      oversized_request["params"]["prompt"] == [{"type": "text", "text": oversized_prompt}])
check("oversized prompt is absent from argv",
      not any(oversized_prompt in str(arg) for arg in oversized["envelope"].command))


class GradeStop(Exception):
    pass


def exact_terminal_record(case):
    record = {}

    def finish(status, error_class, **kwargs):
        record.update({"status": status, "error_class": error_class, **kwargs})
        raise GradeStop()

    result = case["outcome"]
    try:
        d._grade_phase("SPEC-000-1", "SPEC-000", 1, tmp, {"deadline_ts": time.time() + 60},
                       pathlib.Path("/nonexistent-wt"), case["raw"], finish, kw,
                       result.exit_code, case["stderr"], result.last_message or "")
    except GradeStop:
        pass
    return record


# Each real transport failure keeps the pre-migration dispatcher classification exactly.
for label, mode, deadline in [
    ("zero-exit incomplete protocol", "eof", 2),
    ("malformed frame", "protocol", 2),
    ("JSON-RPC error", "jsonrpc", 2),
    ("nonzero process exit", "nonzero", 2),
    ("cancellation", "cancel", 2),
    ("timeout", "timeout", 0.15),
    ("unsupported stop reason", "stop", 2),
]:
    failed = run_adapter(mode, deadline=deadline)
    check(f"{label}: adapter result is nonzero", failed["outcome"].exit_code != 0)
    terminal = exact_terminal_record(failed)
    check(f"{label}: dispatcher records failed_worker_error",
          terminal.get("status") == "failed_worker_error"
          and terminal.get("error_class") == d.ERR_WORKER)
    check(f"{label}: classification is terminal", terminal.get("status") in d.TERMINAL)


# An unexpected exception from drive still kills and reaps a live child.
class FakeProc:
    def __init__(self):
        self.killed = False
        self.waited = False
    def poll(self):
        return None
    def kill(self):
        self.killed = True
    def wait(self):
        self.waited = True
        return -9


fake_proc = FakeProc()
original_popen = va.subprocess.Popen
original_drive = va.kimi_acp.drive
va.subprocess.Popen = lambda *args, **kwargs: fake_proc
va.kimi_acp.drive = lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError("drive boom"))
with open(tmp / "exception-stderr", "w") as error_sink, open(tmp / "exception-events", "wb") as event_sink:
    exception_envelope = va.BuildEnvelope(
        command=["stub"], cwd="/worktree", env=None, stdout=None, stderr=error_sink,
        deadline_seconds=1, isolated=True, runner=None, alias="kimi-code/k3",
        event_sink=event_sink)
    try:
        exception_result = kw.run_build(exception_envelope, "prompt")
    finally:
        va.subprocess.Popen = original_popen
        va.kimi_acp.drive = original_drive
check("drive exception returns a failed build result", exception_result.exit_code != 0)
check("drive exception kills and reaps the live child", fake_proc.killed and fake_proc.waited)


# Dispatcher-only policy stays before invocation. These refusals deliberately use no
# isolated_cmd/Popen/ACP patches; reaching either would make the test error instead of finish.
snap = b"id: SPEC-000\n"
digest = hashlib.sha256(snap).hexdigest()
base_lc = {"spec_digest": digest, "isolation": True, "deadline_ts": 4102444800.0,
           "worker_vendor": "kimi", "reviewer_vendor": "claude",
           "worker_model": "kimi-k3", "worker_effort": "max",
           "worker_unit": "kimi-SPEC-000-1", "cli_aliases": {"kimi-k3": "kimi-code/k3"}}
original_runtime = d.worker_kimi_runtime
d.worker_kimi_runtime = lambda: (["/definitely/not/launched"], [], pathlib.Path("/not/launched"))


def policy_record(lc):
    attempt = tmp / f"policy-{len(list(tmp.glob('policy-*')))}"
    (attempt / "raw").mkdir(parents=True)
    (attempt / "spec-snapshot.yaml").write_bytes(snap)
    record = {}

    def finish(status, error_class, **kwargs):
        record.update({"status": status, "error_class": error_class, **kwargs})
        raise GradeStop()

    try:
        d._run_pipeline("SPEC-000-1", "SPEC-000", 1, attempt, lc,
                        pathlib.Path("/nonexistent-wt"), attempt / "raw", finish)
    except GradeStop:
        pass
    return record


try:
    identity = policy_record({**base_lc, "cli_aliases": {"kimi-k3": "kimi-k3"}})
    ceiling = policy_record({**base_lc, "deadline_ts": time.time() - 1})
finally:
    d.worker_kimi_runtime = original_runtime
check("identity alias refuses pre-invocation as error_launch",
      identity.get("status") == "error_launch" and identity.get("error_class") == d.ERR_LAUNCH)
check("exhausted worker ceiling refuses pre-invocation as error_launch",
      ceiling.get("status") == "error_launch" and ceiling.get("error_class") == d.ERR_TIMEOUT)

raise SystemExit(1 if fails else 0)
PY

if [ $? -eq 0 ]; then echo "PASS kimi_acp_transport.sh"; exit 0
else echo "FAIL kimi_acp_transport.sh"; exit 1; fi
