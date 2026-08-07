#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 -B - "$tmp" <<'PY'
import dataclasses
import importlib.util
import inspect
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import textwrap

root = pathlib.Path.cwd()
tmp = pathlib.Path(sys.argv[1])


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


va = load("worker_build_interface_va", root / "scripts/vendor_adapters.py")
fails = []


def check(name, condition):
    print(("ok   " if condition else "FAIL ") + name)
    if not condition:
        fails.append(name)


check("BuildResult has exactly the frozen fields",
      [f.name for f in dataclasses.fields(va.BuildResult)]
      == ["exit_code", "last_message"])
check("BuildEnvelope has exactly the frozen fields",
      [f.name for f in dataclasses.fields(va.BuildEnvelope)] == [
          "command", "cwd", "env", "stdout", "stderr", "deadline_seconds",
          "isolated", "runner", "alias", "event_sink"])
result = va.BuildResult(0, "message")
try:
    result.exit_code = 1
    frozen = False
except dataclasses.FrozenInstanceError:
    frozen = True
check("BuildResult is immutable", frozen)
check("BuildEnvelope is immutable", va.BuildEnvelope.__dataclass_params__.frozen)
check("Codex run_build has only envelope and prompt",
      list(inspect.signature(va.CodexWorker().run_build).parameters)
      == ["envelope", "prompt"])
check("Kimi run_build has only envelope and prompt",
      list(inspect.signature(va.KimiWorker().run_build).parameters)
      == ["envelope", "prompt"])

# Codex: the dispatcher-owned runner is the sole execution seam. Its capture is also the
# existing recovery artifact, so this checks both exact argument delivery and last-message
# recovery without involving dispatch.py.
codex_raw = tmp / "codex-raw"
codex_raw.mkdir()
events = open(codex_raw / "events.jsonl", "wb")
errors = open(codex_raw / "worker-stderr.txt", "w+")
codex_env = {"ONLY": "dispatcher environment"}
codex_command = ["complete-codex-command", "--json"]
codex_seen = {}


def codex_runner(envelope, prompt):
    codex_seen.update({"envelope": envelope, "prompt": prompt})
    envelope.stdout.write(
        (json.dumps({"item": {"type": "agent_message", "text": "first"}}) + "\n").encode())
    envelope.stdout.write(
        (json.dumps({"item": {"type": "agent_message", "text": "CODEX-FINAL"}}) + "\n").encode())
    return 23


codex_envelope = va.BuildEnvelope(
    command=codex_command, cwd="/dispatcher/worktree", env=codex_env,
    stdout=events, stderr=errors, deadline_seconds=9.5, isolated=True,
    runner=codex_runner, alias=None, event_sink=None)
codex_result = va.CodexWorker().run_build(codex_envelope, "CODEX PROMPT")
check("Codex runner receives the identical envelope", codex_seen.get("envelope") is codex_envelope)
check("Codex runner receives the prompt unchanged", codex_seen.get("prompt") == "CODEX PROMPT")
check("Codex prompt never enters the complete argv", "CODEX PROMPT" not in codex_command)
check("Codex exit status is unaltered", codex_result.exit_code == 23)
check("Codex recovers the existing last agent message", codex_result.last_message == "CODEX-FINAL")

# Compatibility recovery remains the existing worker-last-message file path.
compat_raw = tmp / "compat-raw"
compat_raw.mkdir()
compat_events = open(compat_raw / "events.jsonl", "wb")
compat_errors = open(compat_raw / "worker-stderr.txt", "w+")


def compat_runner(envelope, prompt):
    (compat_raw / "worker-last-message.txt").write_text("FILE-FINAL")
    return 0


compat = va.BuildEnvelope(
    command=["complete", "--output-last-message",
             str(compat_raw / "worker-last-message.txt")],
    cwd="/dispatcher/worktree", env={}, stdout=compat_events, stderr=compat_errors,
    deadline_seconds=3, isolated=False, runner=compat_runner, alias=None, event_sink=None)
check("Codex compatibility path recovers the last-message file",
      va.CodexWorker().run_build(compat, "prompt") == va.BuildResult(0, "FILE-FINAL"))

calls = []


def should_not_run(envelope, prompt):
    calls.append((envelope, prompt))
    return 0


expired_codex = dataclasses.replace(codex_envelope, deadline_seconds=0,
                                    runner=should_not_run)
expired_result = va.CodexWorker().run_build(expired_codex, "prompt")
errors.flush()
errors.seek(0)
check("Codex exhausted deadline returns nonzero", expired_result.exit_code != 0)
check("Codex exhausted deadline refuses before runner", not calls)
check("Codex deadline refusal reaches dispatcher stderr", "deadline" in errors.read())

runner_errors = open(tmp / "runner-errors", "w+")


def broken_runner(envelope, prompt):
    raise OSError("runner exploded")


broken = dataclasses.replace(codex_envelope, stderr=runner_errors,
                             deadline_seconds=1, runner=broken_runner)
broken_result = va.CodexWorker().run_build(broken, "prompt")
runner_errors.seek(0)
check("Codex runner failure returns nonzero", broken_result.exit_code != 0)
check("Codex runner diagnostic reaches dispatcher stderr", "runner exploded" in runner_errors.read())

# The executable is a deterministic ACP peer. It records every request, writes a distinct
# stderr marker, and selects terminal behavior only from its non-prompt argv mode.
stub = tmp / "acp-stub"
stub.write_text(textwrap.dedent(r'''
    #!/usr/bin/python3
    import json, os, signal, sys, time

    mode = sys.argv[1]
    pathlib_marker = os.environ["LAUNCH_MARKER"]
    open(pathlib_marker, "w").write("launched")
    record = os.environ["REQUEST_RECORD"]
    sys.stderr.write("ACP-STDERR\n"); sys.stderr.flush()
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
            sys.stdout.write("not-json\n"); sys.stdout.flush(); time.sleep(30)
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


def run_kimi(mode, deadline=4.75, alias="provider/kimi", isolated=True,
             command=None, module=va):
    case = tmp / ("kimi-" + mode + "-" + str(len(list(tmp.glob("kimi-*")))))
    case.mkdir()
    marker = case / "launched"
    record = case / "requests.jsonl"
    err = open(case / "stderr", "w+")
    sink = open(case / "events.jsonl", "wb")
    env = {"LAUNCH_MARKER": str(marker), "REQUEST_RECORD": str(record)}
    cmd = [str(stub), mode] if command is None else command
    envelope = module.BuildEnvelope(
        command=cmd, cwd="/exact/dispatcher/worktree", env=env, stdout=None,
        stderr=err, deadline_seconds=deadline, isolated=isolated, runner=None,
        alias=alias, event_sink=sink)
    popen_calls = []
    drive_calls = []
    popen_code = subprocess.Popen.__init__.__code__
    drive_code = module.kimi_acp.drive.__code__ if module.kimi_acp is not None else None

    def trace(frame, event, arg):
        if event == "call" and frame.f_code is popen_code:
            popen_calls.append(frame.f_locals.copy())
        if event == "call" and drive_code is not None and frame.f_code is drive_code:
            drive_calls.append(frame.f_locals.copy())
        return trace

    sys.settrace(trace)
    try:
        outcome = module.KimiWorker().run_build(envelope, "KIMI PROMPT")
    finally:
        sys.settrace(None)
        sink.flush()
        err.flush()
    return outcome, envelope, marker, record, err, sink, popen_calls, drive_calls


kimi_result, kimi_envelope, marker, record, err, sink, popen_calls, drive_calls = run_kimi("ok")
check("both vendors return the identical common result type",
      type(kimi_result) is type(codex_result) is va.BuildResult)
check("Kimi maps effective status without reinterpretation", kimi_result.exit_code == 0)
check("Kimi maps final message without reinterpretation", kimi_result.last_message == "KIMI-FINAL")
check("Kimi launches the complete command unchanged",
      len(popen_calls) == 1 and popen_calls[0].get("args") is kimi_envelope.command)
check("Kimi Popen uses stdin=PIPE", popen_calls[0].get("stdin") is subprocess.PIPE)
check("Kimi Popen uses stdout=PIPE", popen_calls[0].get("stdout") is subprocess.PIPE)
check("Kimi Popen uses dispatcher stderr", popen_calls[0].get("stderr") is kimi_envelope.stderr)
check("Kimi Popen uses the complete child environment", popen_calls[0].get("env") is kimi_envelope.env)
check("Kimi prompt never enters argv",
      not any("KIMI PROMPT" in str(arg) for arg in kimi_envelope.command))
check("Kimi ACP executable was launched", marker.exists())
err.seek(0)
check("Kimi child stderr reaches dispatcher sink", "ACP-STDERR" in err.read())
requests = [json.loads(line) for line in record.read_text().splitlines()]
new_request = next(r for r in requests if r["method"] == "session/new")
model_request = next(r for r in requests if r["method"] == "session/set_model")
prompt_request = next(r for r in requests if r["method"] == "session/prompt")
check("Kimi drive receives worktree unchanged",
      new_request["params"]["cwd"] == kimi_envelope.cwd)
check("Kimi drive receives distinct alias unchanged",
      model_request["params"]["modelId"] == kimi_envelope.alias)
check("Kimi drive receives prompt unchanged",
      prompt_request["params"]["prompt"] == [{"type": "text", "text": "KIMI PROMPT"}])
check("Kimi drive receives event sink unchanged",
      len(drive_calls) == 1 and drive_calls[0].get("frame_sink") is kimi_envelope.event_sink)
check("Kimi drive receives remaining deadline unchanged",
      drive_calls[0].get("deadline_s") == kimi_envelope.deadline_seconds)
check("Kimi event sink records raw ACP frames", os.path.getsize(sink.name) > 0)

for label, alias in (("missing", None), ("empty", ""), ("whitespace", " \t"),
                     ("non-string", 17)):
    outcome, envelope, marker, _, err, _, popen, drive = run_kimi(
        "refuse-alias-" + label, alias=alias)
    err.seek(0)
    check("Kimi alias " + label + " returns nonzero", outcome.exit_code != 0)
    check("Kimi alias " + label + " refuses before Popen", not marker.exists() and not popen)
    check("Kimi alias " + label + " reports diagnostic", "alias" in err.read())

outcome, _, marker, _, err, _, popen, _ = run_kimi("refuse-isolation", isolated=False)
check("Kimi non-isolated envelope returns nonzero", outcome.exit_code != 0)
check("Kimi non-isolated envelope refuses before Popen", not marker.exists() and not popen)
err.seek(0)
check("Kimi isolation refusal reports diagnostic", "isolated" in err.read())

outcome, _, marker, _, err, _, popen, _ = run_kimi("refuse-deadline", deadline=0)
check("Kimi exhausted deadline returns nonzero", outcome.exit_code != 0)
check("Kimi exhausted deadline refuses before Popen", not marker.exists() and not popen)
err.seek(0)
check("Kimi deadline refusal reports diagnostic", "deadline" in err.read())

for label, mode in (("ACP protocol failure", "protocol"),
                    ("nonzero process exit", "nonzero"),
                    ("timeout", "timeout"),
                    ("cancellation", "cancel"),
                    ("unsupported stop reason", "stop")):
    deadline = 0.15 if mode == "timeout" else 2
    outcome, *_ = run_kimi(mode, deadline=deadline)
    check(label + " remains nonzero", outcome.exit_code != 0)

missing, _, marker, _, err, _, popen, _ = run_kimi(
    "missing-executable", command=[str(tmp / "does-not-exist")])
err.seek(0)
check("Kimi Popen OSError returns nonzero", missing.exit_code != 0)
check("Kimi Popen OSError reports diagnostic", "No such file" in err.read())
check("Kimi Popen OSError did not start a process", not marker.exists() and len(popen) == 1)

# A copy without kimi_acp.py exercises the import-time pin's fail-closed isolation: importing
# still succeeds, Codex still runs, and only Kimi refuses before its executable can launch.
load_dir = tmp / "load-failure"
load_dir.mkdir()
shutil.copyfile(root / "scripts/vendor_adapters.py", load_dir / "vendor_adapters.py")
va_missing = load("worker_build_interface_missing_acp", load_dir / "vendor_adapters.py")
check("ACP load failure does not block adapter module import", va_missing.kimi_acp is None)
missing_raw = load_dir / "raw"
missing_raw.mkdir()
missing_events = open(missing_raw / "events.jsonl", "wb")
missing_errors = open(missing_raw / "stderr", "w+")


def missing_codex_runner(envelope, prompt):
    envelope.stdout.write(
        (json.dumps({"item": {"type": "agent_message", "text": "CODEX-STILL-WORKS"}})
         + "\n").encode())
    return 0


missing_codex_envelope = va_missing.BuildEnvelope(
    command=["complete"], cwd="/worktree", env={}, stdout=missing_events,
    stderr=missing_errors, deadline_seconds=1, isolated=True,
    runner=missing_codex_runner, alias=None, event_sink=None)
missing_codex_result = va_missing.CodexWorker().run_build(missing_codex_envelope, "prompt")
check("ACP load failure leaves Codex run_build working",
      missing_codex_result == va_missing.BuildResult(0, "CODEX-STILL-WORKS"))
outcome, _, marker, _, err, _, popen, _ = run_kimi("load-failure", module=va_missing)
err.seek(0)
check("ACP load failure blocks Kimi with nonzero result", outcome.exit_code != 0)
check("ACP load failure refuses Kimi before Popen", not marker.exists() and not popen)
check("ACP load failure reaches dispatcher stderr", "failed to load" in err.read())

for handle in (events, errors, compat_events, compat_errors, runner_errors,
               missing_events, missing_errors):
    handle.close()

raise SystemExit(1 if fails else 0)
PY

echo "PASS worker_build_interface.sh"
