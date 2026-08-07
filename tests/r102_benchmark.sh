#!/usr/bin/env bash
# Offline end-state tests for the R102 benchmark adapter and Harbor custom agent.
set -euo pipefail
cd "$(dirname "$0")/.."

export PYTHONDONTWRITEBYTECODE=1
python3 -B - <<'PY'
import asyncio
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap


root = Path.cwd()
tmp = Path(tempfile.mkdtemp(prefix="r102-test-"))
failures = []


def check(name, condition, detail=""):
    print(("ok   " if condition else "FAIL ") + name + (f": {detail}" if detail else ""))
    if not condition:
        failures.append(name)


def run_cli(*arguments, env=None):
    merged = os.environ.copy()
    merged.pop("R102_BENCHMARK", None)
    if env:
        merged.update(env)
    return subprocess.run([str(root / "scripts" / "r102-benchmark"), *map(str, arguments)],
                          text=True, capture_output=True, env=merged)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


try:
    canonical = json.loads((root / "scripts" / "r102_tier_a.json").read_text())
    expected_names = [
        "harness-opus-luna-opus", "harness-opus-luna-none", "harness-opus-sub-opus",
        "harness-opus-k3-k3", "harness-sol-luna-opus", "vanilla-codex",
        "vanilla-claude", "vanilla-kimi",
    ]
    check("canonical row order", [row["name"] for row in canonical] == expected_names)
    check("canonical row kinds", [row["kind"] for row in canonical] ==
          ["harness"] * 5 + ["vanilla"] * 3)
    check("canonical subagent flags",
          [row["name"] for row in canonical if row.get("worker_mode") == "subagent"] ==
          ["harness-opus-sub-opus"] and
          [row["name"] for row in canonical if row["quality_only_fallback"]] ==
          ["harness-opus-sub-opus"])
    check("canonical harness agents", all(
        row["harbor_agent"] == "scripts.r102_harness_agent:RelayHarnessAgent" and
        row["model"] == row["worker"]["model"] for row in canonical[:5]))
    check("canonical vanilla role bindings", all(
        row["orchestrator"] is None and row["worker"] is None and row["reviewer"] is None
        for row in canonical[5:]))

    for path in (root / "scripts" / "r102_benchmark.py",
                 root / "scripts" / "r102_harness_agent.py"):
        compile(path.read_text(), str(path), "exec")
    check("Python sources compile", True)

    unknown = run_cli("other-command")
    unknown_option = run_cli("verify", "--evidence", tmp, "--extra")
    check("unknown CLI surfaces fail", unknown.returncode != 0 and unknown_option.returncode != 0)

    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    versions = {
        "codex": "codex-stub 1", "claude": "claude-stub 2", "kimi": "kimi-stub 3",
        "docker": "docker-stub 4",
    }
    for name, version in versions.items():
        path = bin_dir / name
        path.write_text(f"#!/bin/sh\nprintf '%s\\n' '{version}'\n")
        path.chmod(0o755)

    harbor = bin_dir / "harbor"
    harbor.write_text(textwrap.dedent(r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

if sys.argv[1:] == ["--version"]:
    print("harbor-stub 0.20.0")
    raise SystemExit(0)
if not sys.argv[1:] or sys.argv[1] != "run":
    raise SystemExit(2)
args = sys.argv[2:]
with open(os.environ["HARBOR_RECORD"], "a") as sink:
    sink.write(json.dumps(args) + "\n")

def value(flag):
    return args[args.index(flag) + 1]

agent = value("--agent")
model = value("-m")
task = value("-t")
out = Path(value("-o"))
row = None
if "--ak" in args:
    payload = value("--ak")
    row = json.loads(payload[len("row="):])
name = row["name"] if row else {
    "codex": "vanilla-codex", "claude-code": "vanilla-claude", "kimi-cli": "vanilla-kimi"
}[agent]
if os.environ.get("HARBOR_FAIL_ROW") == name:
    print("stub failure", file=sys.stderr)
    raise SystemExit(9)
out.mkdir(parents=True, exist_ok=True)
(out / "verifier").mkdir()
(out / "verifier" / "reward.json").write_text(json.dumps({"reward": 1}) + "\n")
agent_result = {"n_input_tokens": 31, "n_output_tokens": 17}
if row:
    usage_dir = out / "agent"
    usage_dir.mkdir()
    events = []
    roles = ["orchestrator", "worker"] + (["reviewer"] if row["reviewer"] else [])
    for number, role in enumerate(roles):
        binding = row[role]
        quality = row.get("worker_mode") == "subagent"
        events.append({
            "role": role, "vendor": binding["vendor"], "model": binding["model"],
            "effort": binding["effort"],
            "input_tokens": None if quality else 10 + number,
            "output_tokens": None if quality else 5 + number,
            "wall_s": 0.1, "round": 0 if role != "reviewer" else 1,
        })
    with (usage_dir / "usage.jsonl").open("w") as sink:
        for event in events:
            sink.write(json.dumps(event) + "\n")
    totals = {}
    for event in events:
        target = totals.setdefault(event["role"], {"input_tokens": 0, "output_tokens": 0})
        if event["input_tokens"] is not None:
            target["input_tokens"] += event["input_tokens"]
        if event["output_tokens"] is not None:
            target["output_tokens"] += event["output_tokens"]
    metadata = {
        "config": name, "review_rounds": 0 if row["reviewer"] is None else 1,
        "per_role": totals, "quality_only": row.get("worker_mode") == "subagent",
        "orchestrator_evidence": {
            "vendor": row["orchestrator"]["vendor"],
            "model": row["orchestrator"]["model"], "log": "orchestrator-round-0.log",
        },
    }
    if metadata["quality_only"]:
        metadata["attribution_probe"] = "stub session exposes aggregate usage only"
    (usage_dir / "orchestrator-round-0.log").write_text("stub orchestrator invocation\n")
    agent_result = {"metadata": {"r102": metadata}}
result = {
    "task_name": task, "task_checksum": "task-checksum-pinned",
    "agent_info": {"name": agent, "model": model}, "agent_result": agent_result,
    "verifier_result": {"reward": 1}, "wall_s": 0.2,
}
(out / "result.json").write_text(json.dumps(result) + "\n")
'''))
    harbor.chmod(0o755)
    test_env = {
        "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
        "HARBOR_RECORD": str(tmp / "harbor-record.jsonl"),
    }

    preflight = tmp / "preflight.json"
    result = run_cli("preflight", "--out", preflight, env=test_env)
    preflight_value = json.loads(preflight.read_text())
    check("preflight succeeds", result.returncode == 0, result.stderr)
    check("preflight embeds versions", all(
        preflight_value["cli_versions"][name]["output"] == value
        for name, value in {**versions, "harbor": "harbor-stub 0.20.0"}.items()))
    check("preflight embeds canonical rows", preflight_value["tier_a"] == canonical)
    check("preflight digest", Path(str(preflight) + ".sha256").read_text().strip() == digest(preflight))

    kimi = bin_dir / "kimi"
    kimi_saved = kimi.read_bytes()
    kimi.unlink()
    missing_preflight = tmp / "preflight-missing.json"
    result = run_cli("preflight", "--out", missing_preflight, env=test_env)
    check("preflight records missing probe", result.returncode != 0 and
          json.loads(missing_preflight.read_text())["cli_versions"]["kimi"]["ok"] is False)
    kimi.write_bytes(kimi_saved)
    kimi.chmod(0o755)

    task_manifest = tmp / "task.json"
    task_manifest.write_text(json.dumps({
        "benchmark": "terminal-bench@2.1", "task": "terminal-bench/example-task"
    }) + "\n")
    config_manifest = root / "scripts" / "r102_tier_a.json"
    record = Path(test_env["HARBOR_RECORD"])
    record.write_text("")
    evidence = tmp / "evidence"
    result = run_cli("kill-test", "--benchmark", "terminal-bench@2.1",
                     "--task-manifest", task_manifest, "--config-manifest", config_manifest,
                     "--trials", "1", "--evidence", evidence, env=test_env)
    check("kill-test default-off", result.returncode != 0 and "R102_BENCHMARK=1" in result.stderr)
    check("default-off launches nothing", record.read_text() == "")

    bad_config = tmp / "bad-config.json"
    bad_config.write_text(json.dumps(list(reversed(canonical))))
    enabled = {**test_env, "R102_BENCHMARK": "1"}
    result = run_cli("kill-test", "--benchmark", "terminal-bench@2.1",
                     "--task-manifest", task_manifest, "--config-manifest", bad_config,
                     "--trials", "1", "--evidence", tmp / "bad-config-evidence", env=enabled)
    check("noncanonical config refuses before launch", result.returncode != 0 and record.read_text() == "")
    wrong_task = tmp / "wrong-task.json"
    wrong_task.write_text(json.dumps({"benchmark": "wrong", "task": "terminal-bench/example-task"}))
    result = run_cli("kill-test", "--benchmark", "terminal-bench@2.1",
                     "--task-manifest", wrong_task, "--config-manifest", config_manifest,
                     "--trials", "1", "--evidence", tmp / "bad-task-evidence", env=enabled)
    check("benchmark mismatch refuses before launch", result.returncode != 0 and record.read_text() == "")

    result = run_cli("kill-test", "--benchmark", "terminal-bench@2.1",
                     "--task-manifest", task_manifest, "--config-manifest", config_manifest,
                     "--trials", "1", "--evidence", evidence, env=enabled)
    calls = [json.loads(line) for line in record.read_text().splitlines()]
    check("enabled kill-test succeeds", result.returncode == 0, result.stderr)
    check("exactly eight sequential Harbor calls", len(calls) == 8)
    call_shapes = True
    for row, args in zip(canonical, calls):
        try:
            call_shapes &= args[args.index("--agent") + 1] == row["harbor_agent"]
            call_shapes &= args[args.index("-m") + 1] == row["model"]
            call_shapes &= args[args.index("-t") + 1] == "terminal-bench/example-task"
            call_shapes &= str(evidence / "harbor" / row["name"]) in args[args.index("-o") + 1]
            if row["kind"] == "harness":
                payload = args[args.index("--ak") + 1]
                call_shapes &= json.loads(payload[len("row="):]) == row
            else:
                call_shapes &= "--ak" not in args
        except (ValueError, IndexError, json.JSONDecodeError):
            call_shapes = False
    check("Harbor argv carries exact row bindings", call_shapes)
    manifest = json.loads((evidence / "manifest.json").read_text())
    check("kill-test input digests", manifest["task_manifest_digest"] == digest(task_manifest) and
          manifest["config_manifest_digest"] == digest(config_manifest))
    check("kill-test manifest and raw evidence", len(manifest["rows"]) == 8 and all(
        row["verdict"] == "PASS" and row["grader_raw"] and row["error"] is None
        for row in manifest["rows"]))
    check("kill-test manifest digest",
          (evidence / "manifest.json.sha256").read_text().strip() == digest(evidence / "manifest.json"))

    verify_result = run_cli("verify", "--evidence", evidence, env=test_env)
    expected_checks = [
        "manifest-sha256", "input-digests", "canonical-rows", "common-task", "raw-grader",
        "harness-usage", "vanilla-usage", "reviewer-null", "codex-orchestrator",
        "subagent-attribution",
    ]
    check("verify passing evidence", verify_result.returncode == 0 and all(
        f"ok {name}" in verify_result.stdout for name in expected_checks), verify_result.stdout)

    failed_evidence = tmp / "failed-evidence"
    fail_record = tmp / "fail-record.jsonl"
    fail_record.write_text("")
    fail_env = {**enabled, "HARBOR_RECORD": str(fail_record),
                "HARBOR_FAIL_ROW": "harness-opus-sub-opus"}
    result = run_cli("kill-test", "--benchmark", "terminal-bench@2.1",
                     "--task-manifest", task_manifest, "--config-manifest", config_manifest,
                     "--trials", "1", "--evidence", failed_evidence, env=fail_env)
    failed_manifest = json.loads((failed_evidence / "manifest.json").read_text())
    failed_row = next(row for row in failed_manifest["rows"] if row["name"] ==
                      "harness-opus-sub-opus")
    check("failed row does not stop later rows", result.returncode != 0 and
          len(fail_record.read_text().splitlines()) == 8 and failed_row["error"] and
          failed_manifest["rows"][-1]["verdict"] == "PASS")

    def mutation(name, expected_check, mutate, refresh_manifest=False):
        case = tmp / ("mutation-" + name)
        shutil.copytree(evidence, case)
        mutate(case)
        if refresh_manifest:
            target = case / "manifest.json"
            (case / "manifest.json.sha256").write_text(digest(target) + "\n")
        outcome = run_cli("verify", "--evidence", case, env=test_env)
        check("verify rejects " + name,
              outcome.returncode != 0 and f"FAIL {expected_check}" in outcome.stdout,
              outcome.stdout)

    def edit_manifest(case, editor):
        path = case / "manifest.json"
        value = json.loads(path.read_text())
        editor(value)
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    mutation("deleted row", "canonical-rows",
             lambda case: edit_manifest(case, lambda value: value["rows"].pop()), True)

    def change_checksum(case):
        result_path = case / "harbor" / expected_names[0] / "trial-1" / "result.json"
        result_value = json.loads(result_path.read_text())
        result_value["task_checksum"] = "different-checksum"
        result_path.write_text(json.dumps(result_value))
        edit_manifest(case, lambda value: value["rows"][0].update(
            {"task_checksum": "different-checksum"}))
    mutation("different task checksum", "common-task", change_checksum, True)

    mutation("removed raw grader", "raw-grader",
             lambda case: (case / "harbor" / expected_names[0] / "trial-1" /
                           "verifier" / "reward.json").unlink())
    mutation("contradicting verdict", "raw-grader",
             lambda case: edit_manifest(case, lambda value: value["rows"][0].update(
                 {"verdict": "FAIL"})), True)

    def remove_worker_usage(case):
        usage_path = case / "harbor" / expected_names[0] / "trial-1" / "agent" / "usage.jsonl"
        events = [json.loads(line) for line in usage_path.read_text().splitlines()]
        events = [event for event in events if event["role"] != "worker"]
        usage_path.write_text("".join(json.dumps(event) + "\n" for event in events))
        edit_manifest(case, lambda value: value["rows"][0].update({"usage": events}))
    mutation("missing harness worker usage", "harness-usage", remove_worker_usage, True)

    def remove_vanilla_totals(case):
        path = case / "harbor" / "vanilla-codex" / "trial-1" / "result.json"
        value = json.loads(path.read_text())
        value["agent_result"].pop("n_output_tokens")
        path.write_text(json.dumps(value))
    mutation("missing vanilla totals", "vanilla-usage", remove_vanilla_totals)
    mutation("reviewer-null rounds", "reviewer-null",
             lambda case: edit_manifest(case, lambda value: value["rows"][1].update(
                 {"review_rounds": 1})), True)
    mutation("wrong Codex orchestrator", "codex-orchestrator",
             lambda case: edit_manifest(case, lambda value: value["rows"][4][
                 "orchestrator_evidence"].update({"vendor": "claude"})), True)
    mutation("missing subagent fallback", "subagent-attribution",
             lambda case: edit_manifest(case, lambda value: value["rows"][2].update(
                 {"quality_only": False})), True)
    mutation("flipped manifest byte", "manifest-sha256",
             lambda case: (case / "manifest.json").write_bytes(
                 (case / "manifest.json").read_bytes() + b" "))
    mutation("task input digest", "input-digests",
             lambda case: (case / "task-manifest.json").write_bytes(
                 (case / "task-manifest.json").read_bytes() + b" "))
    mutation("config input digest", "input-digests",
             lambda case: (case / "config-manifest.json").write_bytes(
                 (case / "config-manifest.json").read_bytes() + b" "))

    fake = tmp / "fake-harbor"
    for relative, body in {
        "harbor/__init__.py": "",
        "harbor/agents/__init__.py": "",
        "harbor/agents/base.py": '''class BaseAgent:\n    def __init__(self, logs_dir, *args, **kwargs):\n        self.base_logs_dir = logs_dir\n''',
        "harbor/models/__init__.py": "",
        "harbor/models/agent/__init__.py": "",
        "harbor/models/agent/context.py": '''class AgentContext:\n    def __init__(self):\n        self.n_input_tokens = 0\n        self.n_output_tokens = 0\n        self.cost_usd = 0\n        self.metadata = None\n''',
    }.items():
        path = fake / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
    sys.path.insert(0, str(fake))
    spec = importlib.util.spec_from_file_location("r102_agent", root / "scripts" /
                                                  "r102_harness_agent.py")
    agent_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(agent_module)

    class Environment:
        def __init__(self, order, tokenized=True):
            self.order = order
            self.tokenized = tokenized
        async def exec(self, command):
            orchestrator = "--safe-mode" in command and "--resume" not in command
            self.order.append(("orchestrator" if orchestrator else "worker", command))
            if orchestrator:
                usage = {"input_tokens": 12, "output_tokens": 6} if self.tokenized else {}
                return {"stdout": json.dumps({
                    "result": "worker brief", "session_id": "session-1", "usage": usage,
                }), "stderr": "", "returncode": 0}
            suffix = '\n{"usage":{"input_tokens":20,"output_tokens":8}}' if self.tokenized else ""
            return {"stdout": "worker complete" + suffix, "stderr": "", "returncode": 0}

    all_agent_orders = []

    async def exercise(row, reviewer_outputs, tokenized=True):
        order = []
        logs = tmp / ("agent-" + row["name"] + "-" + str(len(list(tmp.glob("agent-*")))))
        agent = agent_module.RelayHarnessAgent(logs, row=json.dumps(row))
        outputs = iter(reviewer_outputs)
        def local(command, prompt):
            role = "reviewer" if "Review the benchmark" in prompt else "orchestrator"
            order.append((role, command))
            if role == "reviewer":
                text = next(outputs)
            else:
                text = "worker brief"
            if tokenized:
                text += '\n{"usage":{"input_tokens":12,"output_tokens":6}}'
            return subprocess.CompletedProcess(command, 0, text, "")
        agent._subprocess_run = local
        context = agent_module.AgentContext()
        await agent.run("implement task", Environment(order, tokenized), context)
        events = [json.loads(line) for line in agent.usage_path.read_text().splitlines()]
        all_agent_orders.extend(order)
        return order, context, events

    order, context, events = asyncio.run(exercise(canonical[0], ["REVISE fix it", "PASS good"]))
    check("agent role ordering", [role for role, _ in order] ==
          ["orchestrator", "worker", "reviewer", "worker", "reviewer"])
    check("agent stops review on PASS", context.metadata["r102"]["review_rounds"] == 2 and
          [event["role"] for event in events].count("reviewer") == 2)
    check("agent context token sums", context.n_input_tokens == sum(
        event["input_tokens"] for event in events) and context.n_output_tokens == sum(
        event["output_tokens"] for event in events))
    check("agent usage carries bound role identities", all(
        all(event[key] == canonical[0][event["role"]][key]
            for key in ("vendor", "model", "effort")) for event in events))
    check("agent orchestrator evidence", context.metadata["r102"]["orchestrator_evidence"] == {
        "vendor": "claude", "model": "claude-opus-4-8", "log": "orchestrator-round-0.log"})

    order, context, events = asyncio.run(exercise(canonical[1], []))
    check("agent reviewer-null row", [role for role, _ in order] == ["orchestrator", "worker"] and
          not any(event["role"] == "reviewer" for event in events) and
          context.metadata["r102"]["review_rounds"] == 0)
    order, context, events = asyncio.run(exercise(canonical[0], ["REVISE"] * 5))
    check("agent review cap", [event["role"] for event in events].count("reviewer") == 5 and
          context.metadata["r102"]["review_rounds"] == 5)
    order, context, events = asyncio.run(exercise(canonical[2], ["PASS"], tokenized=False))
    check("agent unknown tokens stay null", all(
        event["input_tokens"] is None and event["output_tokens"] is None for event in events) and
        context.n_input_tokens == 0 and context.n_output_tokens == 0)
    check("agent subagent fallback", context.metadata["r102"]["quality_only"] is True and
          context.metadata["r102"]["attribution_probe"])
    subagent_commands = [command for role, command in order if role == "worker"]
    check("agent resumes orchestrator session for subagent", len(subagent_commands) == 1 and
          "--resume session-1" in subagent_commands[0] and "--agents" in subagent_commands[0])
    forbidden = ("git push", " gh ", " merge ", " promotion ")
    check("agent invokes no publishing mechanics", not any(
        any(term in (" " + (command if isinstance(command, str) else " ".join(command)) +
             " ").lower() for term in forbidden) for _, command in all_agent_orders))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

if failures:
    print(f"{len(failures)} r102 benchmark test(s) failed", file=sys.stderr)
    raise SystemExit(1)
print("all r102 benchmark tests passed")
PY
