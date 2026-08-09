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
        for key, value in env.items():
            if value is None:
                merged.pop(key, None)
            else:
                merged[key] = value
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
    k3_row = next(row for row in canonical if row["name"] == "harness-opus-k3-k3")
    check("Kimi harness bindings use configured model",
          k3_row["model"] == k3_row["worker"]["model"] ==
          k3_row["reviewer"]["model"] == "kimi-code/k3" and
          canonical[-1]["model"] == "kimi-k3")
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
    sink.write(json.dumps({
        "args": args,
        "env": {key: os.environ[key] for key in
                ("CODEX_FORCE_AUTH_JSON", "CLAUDE_CODE_OAUTH_TOKEN") if key in os.environ},
    }) + "\n")

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
(out / "result.json").write_text(json.dumps({"verifier_result": {"reward": 0}}) + "\n")
job_dir = out / "2026-08-07__22-40-02"
job_dir.mkdir()
(job_dir / "result.json").write_text(json.dumps({"job": name}) + "\n")
trial_name = task.rsplit("/", 1)[-1][:32].rstrip("_-") + "__3Je9AaN"
trial_dir = job_dir / trial_name
layout_error = os.environ.get("HARBOR_LAYOUT_ERROR")
if layout_error != "zero:" + name:
    trial_dir.mkdir()
    (trial_dir / "verifier").mkdir()
    (trial_dir / "verifier" / "reward.json").write_text(json.dumps({"reward": 1}) + "\n")
if layout_error == "multiple:" + name:
    duplicate = job_dir / (trial_name + "-duplicate")
    duplicate.mkdir()
    (duplicate / "verifier").mkdir()
    (duplicate / "verifier" / "reward.txt").write_text("1\n")
    (duplicate / "result.json").write_text(json.dumps({"verifier_result": {"reward": 1}}))
agent_result = {"n_input_tokens": 31, "n_output_tokens": 17}
if row:
    usage_dir = trial_dir / "agent"
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
if trial_dir.is_dir():
    (trial_dir / "result.json").write_text(json.dumps(result) + "\n")
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

    decoy_dir = tmp / "decoy-bin"
    decoy_dir.mkdir()
    decoy_kimi = decoy_dir / "kimi"
    decoy_kimi.write_text("#!/bin/sh\nprintf '%s\\n' 'kimi-decoy 0'\n")
    decoy_kimi.chmod(0o755)
    kimi = bin_dir / "kimi"
    kimi_saved = kimi.read_bytes()
    kimi_mode = kimi.stat().st_mode & 0o7777
    kimi.write_text("#!/bin/sh\nexit 127\n")
    kimi.chmod(kimi_mode)
    missing_preflight = tmp / "preflight-missing.json"
    failed_probe_env = {**test_env, "PATH": os.pathsep.join(
        (str(bin_dir), str(decoy_dir), os.environ["PATH"]))}
    result = run_cli("preflight", "--out", missing_preflight, env=failed_probe_env)
    check("preflight records missing probe", result.returncode != 0 and
          json.loads(missing_preflight.read_text())["cli_versions"]["kimi"]["ok"] is False)
    kimi.write_bytes(kimi_saved)
    kimi.chmod(kimi_mode)

    task_manifest = tmp / "task.json"
    task_manifest.write_text(json.dumps({
        "benchmark": "terminal-bench@2.1", "task": "terminal-bench/example-task"
    }) + "\n")
    config_manifest = root / "scripts" / "r102_tier_a.json"
    host_home = tmp / "host-home"
    claude_credentials = host_home / ".claude" / ".credentials.json"
    claude_credentials.parent.mkdir(parents=True)
    fixture_token = "fixture-claude-oauth-secret"
    claude_credentials.write_text(json.dumps({
        "claudeAiOauth": {"accessToken": fixture_token}
    }))
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
    enabled = {**test_env, "R102_BENCHMARK": "1", "R102_HOST_HOME": str(host_home),
               "CLAUDE_CODE_OAUTH_TOKEN": None}
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
    for row, call in zip(canonical, calls):
        args = call["args"]
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
    check("Harbor receives forced Codex auth and fixture Claude token", all(
        call["env"] == {"CODEX_FORCE_AUTH_JSON": "1",
                        "CLAUDE_CODE_OAUTH_TOKEN": fixture_token} for call in calls))
    check("secrets stay out of argv, manifest, and output", all(
        fixture_token not in json.dumps(call["args"]) for call in calls) and
        fixture_token not in (evidence / "manifest.json").read_text() and
        fixture_token not in result.stdout + result.stderr)
    check("kill-test input digests", manifest["task_manifest_digest"] == digest(task_manifest) and
          manifest["config_manifest_digest"] == digest(config_manifest))
    check("kill-test manifest and raw evidence", len(manifest["rows"]) == 8 and all(
        row["verdict"] == "PASS" and row["grader_raw"] and row["error"] is None
        for row in manifest["rows"]))
    check("kill-test records resolved nested trial dirs", all(
        len(row["trial_dirs"]) == 1 and
        "/2026-08-07__22-40-02/example-task__3Je9AaN" in row["trial_dirs"][0]
        for row in manifest["rows"]))
    check("flat contradictory result is ignored", all(
        row["verdict"] == "PASS" for row in manifest["rows"]))
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

    preset_record = tmp / "preset-record.jsonl"
    preset_record.write_text("")
    preset_token = "caller-supplied-claude-token"
    preset_env = {**enabled, "HARBOR_RECORD": str(preset_record),
                  "CLAUDE_CODE_OAUTH_TOKEN": preset_token}
    preset_result = run_cli(
        "kill-test", "--benchmark", "terminal-bench@2.1",
        "--task-manifest", task_manifest, "--config-manifest", config_manifest,
        "--trials", "1", "--evidence", tmp / "preset-evidence", env=preset_env)
    preset_calls = [json.loads(line) for line in preset_record.read_text().splitlines()]
    check("pre-set Claude token is passed through unreplaced",
          preset_result.returncode == 0 and len(preset_calls) == 8 and all(
              call["env"].get("CLAUDE_CODE_OAUTH_TOKEN") == preset_token
              for call in preset_calls))

    missing_record = tmp / "missing-credential-record.jsonl"
    missing_record.write_text("")
    missing_env = {**enabled, "HARBOR_RECORD": str(missing_record),
                   "R102_HOST_HOME": str(tmp / "absent-host-home")}
    missing_result = run_cli(
        "kill-test", "--benchmark", "terminal-bench@2.1",
        "--task-manifest", task_manifest, "--config-manifest", config_manifest,
        "--trials", "1", "--evidence", tmp / "missing-credential-evidence",
        env=missing_env)
    missing_calls = [json.loads(line) for line in missing_record.read_text().splitlines()]
    check("missing Claude credential is silently skipped",
          missing_result.returncode == 0 and len(missing_calls) == 8 and all(
              "CLAUDE_CODE_OAUTH_TOKEN" not in call["env"] for call in missing_calls))

    def layout_failure(kind):
        layout_record = tmp / (kind + "-layout-record.jsonl")
        layout_record.write_text("")
        row_name = expected_names[0]
        layout_evidence = tmp / (kind + "-layout-evidence")
        layout_env = {**enabled, "HARBOR_RECORD": str(layout_record),
                      "HARBOR_LAYOUT_ERROR": kind + ":" + row_name}
        outcome = run_cli(
            "kill-test", "--benchmark", "terminal-bench@2.1",
            "--task-manifest", task_manifest, "--config-manifest", config_manifest,
            "--trials", "1", "--evidence", layout_evidence, env=layout_env)
        value = json.loads((layout_evidence / "manifest.json").read_text())
        launch_dir = layout_evidence / "harbor" / row_name / "trial-1"
        return outcome, value, launch_dir, layout_record

    zero_result, zero_manifest, zero_launch, zero_record = layout_failure("zero")
    check("zero trial candidates records row error and continues",
          zero_result.returncode != 0 and
          str(zero_launch) in zero_manifest["rows"][0]["error"] and
          "candidates found: none" in zero_manifest["rows"][0]["error"] and
          zero_manifest["rows"][-1]["verdict"] == "PASS" and
          len(zero_record.read_text().splitlines()) == 8)
    multiple_result, multiple_manifest, multiple_launch, multiple_record = layout_failure(
        "multiple")
    check("multiple trial candidates records row error and continues",
          multiple_result.returncode != 0 and
          str(multiple_launch) in multiple_manifest["rows"][0]["error"] and
          "example-task__3Je9AaN" in multiple_manifest["rows"][0]["error"] and
          "duplicate" in multiple_manifest["rows"][0]["error"] and
          multiple_manifest["rows"][-1]["verdict"] == "PASS" and
          len(multiple_record.read_text().splitlines()) == 8)

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

    def retained_trial(case, row_number):
        value = json.loads((case / "manifest.json").read_text())
        return case / value["rows"][row_number]["trial_dirs"][0]

    mutation("deleted row", "canonical-rows",
             lambda case: edit_manifest(case, lambda value: value["rows"].pop()), True)

    def change_checksum(case):
        result_path = retained_trial(case, 0) / "result.json"
        result_value = json.loads(result_path.read_text())
        result_value["task_checksum"] = "different-checksum"
        result_path.write_text(json.dumps(result_value))
        edit_manifest(case, lambda value: value["rows"][0].update(
            {"task_checksum": "different-checksum"}))
    mutation("different task checksum", "common-task", change_checksum, True)

    mutation("removed raw grader", "raw-grader",
             lambda case: (retained_trial(case, 0) / "verifier" / "reward.json").unlink())
    mutation("contradicting verdict", "raw-grader",
             lambda case: edit_manifest(case, lambda value: value["rows"][0].update(
                 {"verdict": "FAIL"})), True)

    def remove_worker_usage(case):
        usage_path = retained_trial(case, 0) / "agent" / "usage.jsonl"
        events = [json.loads(line) for line in usage_path.read_text().splitlines()]
        events = [event for event in events if event["role"] != "worker"]
        usage_path.write_text("".join(json.dumps(event) + "\n" for event in events))
        edit_manifest(case, lambda value: value["rows"][0].update({"usage": events}))
    mutation("missing harness worker usage", "harness-usage", remove_worker_usage, True)

    def remove_vanilla_totals(case):
        path = retained_trial(case, 5) / "result.json"
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
        "harbor/agents/installed/__init__.py": "",
        "harbor/agents/installed/codex.py": '''class Codex:\n    def __init__(self, logs_dir, model_name=None, **kwargs):\n        self.logs_dir = logs_dir\n        self.model_name = model_name\n    async def setup(self, environment):\n        environment.installs.append(("codex", self.logs_dir, self.model_name))\n''',
        "harbor/agents/installed/claude_code.py": '''class ClaudeCode:\n    def __init__(self, logs_dir, model_name=None, **kwargs):\n        self.logs_dir = logs_dir\n        self.model_name = model_name\n    async def setup(self, environment):\n        environment.installs.append(("claude", self.logs_dir, self.model_name))\n''',
        "harbor/agents/installed/kimi_cli.py": '''class KimiCli:\n    def __init__(self, logs_dir, model_name=None, **kwargs):\n        self.logs_dir = logs_dir\n        self.model_name = model_name\n    async def setup(self, environment):\n        environment.installs.append(("kimi", self.logs_dir, self.model_name))\n''',
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

    dict_agent = agent_module.RelayHarnessAgent(tmp / "agent-dict", row=canonical[0])
    string_agent = agent_module.RelayHarnessAgent(
        tmp / "agent-string", row=json.dumps(canonical[0]))
    check("agent accepts parsed dict row", dict_agent.row == string_agent.row)
    invalid_type_errors = []
    for invalid_row in (None, 42):
        try:
            agent_module.RelayHarnessAgent(tmp / "agent-invalid", row=invalid_row)
        except ValueError as exc:
            invalid_type_errors.append("agent kwarg row=<json>" in str(exc))
    check("agent rejects invalid row types", invalid_type_errors == [True, True])
    try:
        agent_module.RelayHarnessAgent(tmp / "agent-invalid-json", row="not-json")
    except ValueError as exc:
        invalid_json_error = "invalid row agent kwarg" in str(exc)
    else:
        invalid_json_error = False
    check("agent rejects invalid row JSON", invalid_json_error)

    class Environment:
        def __init__(self, order, tokenized=True, reviewer_outputs=None):
            self.order = order
            self.tokenized = tokenized
            self.reviewer_outputs = reviewer_outputs or iter(())
        async def exec(self, command):
            if "python3 -c" in command:
                return {"stdout": json.dumps({
                    "pwd": "/workspace/task", "files": {"README.md": "fixture"},
                }), "stderr": "", "returncode": 0}
            if "Review the benchmark" in command:
                role = "reviewer"
            elif "--resume" in command or "Remediate the review findings" in command:
                role = "worker"
            elif "--safe-mode" in command or "Produce a concise worker brief" in command:
                role = "orchestrator"
            else:
                role = "worker"
            self.order.append((role, command))
            if role == "orchestrator":
                usage = {"input_tokens": 12, "output_tokens": 6} if self.tokenized else {}
                return {"stdout": json.dumps({
                    "result": "worker brief", "session_id": "session-1", "usage": usage,
                }), "stderr": "", "returncode": 0}
            if role == "reviewer":
                review = next(self.reviewer_outputs, "PASS")
                usage = {"input_tokens": 12, "output_tokens": 6} if self.tokenized else {}
                return {"stdout": json.dumps({
                    "result": review, "session_id": "review-session", "usage": usage,
                }), "stderr": "", "returncode": 0}
            if "codex exec" not in command:
                usage = {"input_tokens": 20, "output_tokens": 8} if self.tokenized else {}
                return {"stdout": json.dumps({
                    "result": "worker complete", "usage": usage,
                }), "stderr": "", "returncode": 0}
            suffix = '\n{"usage":{"input_tokens":20,"output_tokens":8}}' if self.tokenized else ""
            return {"stdout": "worker complete" + suffix, "stderr": "", "returncode": 0}

    class SetupEnvironment:
        default_user = "benchmark"

        def __init__(self):
            self.installs = []
            self.exec_calls = []
            self.uploads = []

        async def exec(self, command, env=None, user=None):
            self.exec_calls.append((command, env, user))
            if "python3 -c" in command:
                return {"stdout": json.dumps({
                    "pwd": "/workspace/task", "files": {"README.md": "fixture"},
                }), "stderr": "", "returncode": 0}
            if command == 'printf %s "$HOME"':
                return {"stdout": "/home/benchmark", "stderr": "", "returncode": 0}
            if "Review the benchmark" in command:
                return {"stdout": json.dumps({
                    "result": "PASS", "usage": {"input_tokens": 12, "output_tokens": 6},
                }), "stderr": "", "returncode": 0}
            if "claude -p" in command and "--resume" not in command:
                return {"stdout": json.dumps({
                    "result": "worker brief", "session_id": "session-1",
                    "usage": {"input_tokens": 12, "output_tokens": 6},
                }), "stderr": "", "returncode": 0}
            if "claude -p" in command:
                return {"stdout": json.dumps({
                    "result": "worker complete",
                    "usage": {"input_tokens": 20, "output_tokens": 8},
                }), "stderr": "", "returncode": 0}
            return {"stdout": "", "stderr": "", "returncode": 0}

        async def upload_file(self, source, target):
            self.uploads.append(("file", Path(source), Path(target)))

        async def upload_dir(self, source, target):
            self.uploads.append(("dir", Path(source), Path(target)))

    snapshot_command = (
        "python3 -c 'import json; print(json.dumps({\"pwd\": \"/workspace/task\", "
        "\"files\": {\"README.md\": \"fixture\"}}))'"
    )
    for fixture_name, fixture in (("Environment", Environment([], True)),
                                  ("SetupEnvironment", SetupEnvironment())):
        try:
            snapshot_result = asyncio.run(fixture.exec(snapshot_command))
            snapshot = json.loads(snapshot_result["stdout"])
            snapshot_valid = (snapshot_result["returncode"] == 0 and
                              isinstance(snapshot.get("pwd"), str) and
                              isinstance(snapshot.get("files"), dict))
        except (KeyError, TypeError, json.JSONDecodeError):
            snapshot_valid = False
        check(f"{fixture_name} answers workspace snapshot", snapshot_valid)

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
        await agent.run("implement task", Environment(order, tokenized, outputs), context)
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
    required_usage_keys = ("role", "vendor", "model", "effort")
    check("agent usage carries bound role identities", all(
        isinstance(event, dict) and all(key in event for key in required_usage_keys) and
        event["role"] in canonical[0] and
        all(event[key] == canonical[0][event["role"]][key]
            for key in ("vendor", "model", "effort")) for event in events))
    orchestrator_evidence = context.metadata["r102"]["orchestrator_evidence"]
    check("agent orchestrator evidence", isinstance(orchestrator_evidence, dict) and
          orchestrator_evidence.get("vendor") == "claude" and
          orchestrator_evidence.get("model") == "claude-opus-4-8" and
          orchestrator_evidence.get("log") == "orchestrator-round-0.log")
    codex_locator = "if [ -s ~/.nvm/nvm.sh ]; then . ~/.nvm/nvm.sh; fi; "
    check("in-container Codex worker uses the nvm locator",
          all(isinstance(command, str) and command.startswith(codex_locator) and
              "codex exec" in command and " | codex exec " in command
              for role, command in order if role == "worker"))
    def invokes_vendor(command, vendor):
        if isinstance(command, list):
            return bool(command) and command[0] == vendor
        return isinstance(command, str) and f"{vendor} " in command

    check("non-worker role invocations use the bound vendor",
          all(invokes_vendor(command, canonical[0][role]["vendor"])
              for role, command in order if role in {"orchestrator", "reviewer"}))

    setup_home = tmp / "setup-host-home"
    codex_auth = setup_home / ".codex" / "auth.json"
    codex_auth.parent.mkdir(parents=True)
    codex_auth.write_text('{"tokens":"fixture"}\n')
    kimi_credentials = setup_home / ".kimi-code" / "credentials"
    kimi_credentials.mkdir(parents=True)
    (kimi_credentials / "oauth.json").write_text('{"oauth":"fixture"}\n')
    setup_claude_credentials = setup_home / ".claude" / ".credentials.json"
    setup_claude_credentials.parent.mkdir(parents=True)
    setup_token = "setup-fixture-claude-secret"
    setup_claude_credentials.write_text(json.dumps({
        "claudeAiOauth": {"accessToken": setup_token}
    }))
    agent_module.HOST_HOME = setup_home
    saved_claude_token = os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)

    async def prepare(row, label):
        logs = tmp / ("setup-agent-" + label)
        agent = agent_module.RelayHarnessAgent(logs, row=json.dumps(row))
        environment = SetupEnvironment()
        await agent.setup(environment)
        return agent, environment

    codex_agent, codex_environment = asyncio.run(prepare(canonical[0], "codex"))
    check("setup installs only the in-container Codex worker vendor",
          ("codex", canonical[0]["worker"]["model"]) in
          [(vendor, model) for vendor, _, model in codex_environment.installs] and
          all(Path(logs).is_relative_to(codex_agent.logs_dir)
              for _, logs, _ in codex_environment.installs) and
          {vendor for vendor, _, _ in codex_environment.installs} <=
          {"codex", canonical[0]["orchestrator"]["vendor"],
           canonical[0]["reviewer"]["vendor"]})
    check("setup uploads Codex auth into the container home",
          codex_environment.uploads == [
              ("file", codex_auth, Path("/home/benchmark/.codex/auth.json"))])
    check("setup resolves home once and chowns Codex credentials",
          sum(command == 'printf %s "$HOME"'
              for command, _, _ in codex_environment.exec_calls) == 1 and
          any(command == "chown -R benchmark /home/benchmark/.codex" and user == "root"
              for command, _, user in codex_environment.exec_calls))
    check("non-subagent setup skips host orchestrator and reviewer vendors",
          {"codex"} <= {vendor for vendor, _, _ in codex_environment.installs} <=
          {"codex", canonical[0]["orchestrator"]["vendor"],
           canonical[0]["reviewer"]["vendor"]})

    kimi_agent, kimi_environment = asyncio.run(prepare(canonical[3], "kimi"))
    check("setup installs the in-container Kimi worker vendor",
          ("kimi", canonical[3]["worker"]["model"]) in
          [(vendor, model) for vendor, _, model in kimi_environment.installs] and
          all(Path(logs).is_relative_to(kimi_agent.logs_dir)
              for _, logs, _ in kimi_environment.installs) and
          {"kimi"} <= {vendor for vendor, _, _ in kimi_environment.installs} <=
          {"kimi", canonical[3]["orchestrator"]["vendor"],
           canonical[3]["reviewer"]["vendor"]})
    check("setup without Kimi config uploads credentials only",
          not (setup_home / ".kimi-code" / "config.toml").exists() and
          kimi_environment.uploads == [
              ("dir", kimi_credentials, Path("/home/benchmark/.kimi-code/credentials"))])
    check("setup chowns Kimi credentials to the container user",
          any(command ==
              "chown -R benchmark /home/benchmark/.kimi-code/credentials" and user == "root"
              for command, _, user in kimi_environment.exec_calls))

    kimi_config = setup_home / ".kimi-code" / "config.toml"
    kimi_config.write_text("[models]\n")
    _, kimi_config_environment = asyncio.run(prepare(canonical[3], "kimi-config"))
    check("setup uploads Kimi config when present",
          kimi_config_environment.uploads == [
              ("dir", kimi_credentials, Path("/home/benchmark/.kimi-code/credentials")),
              ("file", kimi_config, Path("/home/benchmark/.kimi-code/config.toml"))])
    check("setup chowns Kimi config when present",
          any(command == "chown -R benchmark /home/benchmark/.kimi-code/config.toml" and
              user == "root" for command, _, user in kimi_config_environment.exec_calls))

    kimi_binary = setup_home / ".kimi-code" / "bin" / "kimi"
    kimi_binary.parent.mkdir(parents=True)
    kimi_binary.write_text("kimi-code fixture\n")
    kimi_binary.chmod(0o755)
    kimi_oauth = setup_home / ".kimi-code" / "oauth"
    kimi_oauth.mkdir()
    (kimi_oauth / "device.json").write_text("fixture\n")
    kimi_device_id = setup_home / ".kimi-code" / "device_id"
    kimi_device_id.write_text("device-fixture\n")
    _, native_kimi_environment = asyncio.run(prepare(canonical[3], "kimi-native"))
    native_binary_target = Path("/home/benchmark/.local/bin/kimi")
    native_oauth_target = Path("/home/benchmark/.kimi-code/oauth")
    native_device_target = Path("/home/benchmark/.kimi-code/device_id")
    check("native Kimi setup skips the installed Kimi vendor",
          not any(vendor == "kimi" for vendor, _, _ in native_kimi_environment.installs))
    check("native Kimi setup uploads binary and auth paths",
          native_kimi_environment.uploads == [
              ("file", kimi_binary, native_binary_target),
              ("dir", kimi_credentials, Path("/home/benchmark/.kimi-code/credentials")),
              ("file", kimi_config, Path("/home/benchmark/.kimi-code/config.toml")),
              ("dir", kimi_oauth, native_oauth_target),
              ("file", kimi_device_id, native_device_target)])
    native_execs = {(command, user) for command, _, user in native_kimi_environment.exec_calls}
    check("native Kimi setup marks the binary executable",
          ("chmod +x /home/benchmark/.local/bin/kimi", "root") in native_execs)
    check("native Kimi setup chowns every uploaded path",
          all((f"chown -R benchmark {path}", "root") in native_execs for path in (
              "/home/benchmark/.local/bin/kimi",
              "/home/benchmark/.kimi-code/credentials",
              "/home/benchmark/.kimi-code/config.toml",
              "/home/benchmark/.kimi-code/oauth",
              "/home/benchmark/.kimi-code/device_id")))

    fallback_home = tmp / "setup-host-home-kimi-fallback"
    fallback_claude_credentials = fallback_home / ".claude" / ".credentials.json"
    fallback_claude_credentials.parent.mkdir(parents=True)
    fallback_claude_credentials.write_text(json.dumps({
        "claudeAiOauth": {"accessToken": setup_token}
    }))
    fallback_credentials = fallback_home / ".kimi-code" / "credentials"
    fallback_credentials.mkdir(parents=True)
    (fallback_credentials / "oauth.json").write_text('{"oauth":"fixture"}\n')
    fallback_config = fallback_home / ".kimi-code" / "config.toml"
    fallback_config.write_text("[models]\n")
    (fallback_home / ".kimi-code" / "oauth").mkdir()
    (fallback_home / ".kimi-code" / "device_id").write_text("device-fixture\n")
    agent_module.HOST_HOME = fallback_home
    _, fallback_kimi_environment = asyncio.run(prepare(canonical[3], "kimi-fallback"))
    check("Kimi fallback keeps native auth out without the binary",
          any(vendor == "kimi" for vendor, _, _ in fallback_kimi_environment.installs) and
          all(upload in fallback_kimi_environment.uploads for upload in [
              ("dir", fallback_credentials, Path("/home/benchmark/.kimi-code/credentials")),
              ("file", fallback_config, Path("/home/benchmark/.kimi-code/config.toml"))]))
    agent_module.HOST_HOME = setup_home

    kimi_order, _, _ = asyncio.run(exercise(canonical[3], ["PASS"]))
    kimi_locator = 'export PATH="$HOME/.local/bin:$PATH"; '
    check("in-container Kimi worker uses the local-bin locator",
          all(isinstance(command, str) and command.startswith(kimi_locator) and
              "kimi -p" in command for role, command in kimi_order if role == "worker"))
    check("host-side Kimi reviewer has no locator prefix",
          all(invokes_vendor(command, "kimi")
              for role, command in kimi_order if role == "reviewer"))

    wire_home = tmp / "kimi-wire-home"
    wire_path = (wire_home / ".kimi-code" / "sessions" / "workdir-slug" /
                 "session-host" / "agents" / "main" / "wire.jsonl")
    wire_path.parent.mkdir(parents=True)
    wire_events = [
        {"type": "usage.record", "usage": {
            "inputOther": 100, "inputCacheRead": 200, "inputCacheCreation": 300,
            "output": 7}},
        {"type": "usage.record", "usage": {
            "inputOther": 4, "inputCacheRead": 5, "inputCacheCreation": 6,
            "output": 8}},
    ]
    wire_text = "".join(json.dumps(event) + "\n" for event in wire_events)
    wire_path.write_text(wire_text)
    kimi_output = (json.dumps({"role": "assistant", "content": "answer"}) + "\n" +
                   json.dumps({"role": "meta", "type": "session.resume_hint",
                               "session_id": "session-host"}) + "\n")
    agent_module.HOST_HOME = wire_home
    host_wire_agent = agent_module.RelayHarnessAgent(
        tmp / "agent-kimi-host-wire", row=json.dumps(canonical[3]))
    host_wire_agent._subprocess_run = lambda command, prompt: subprocess.CompletedProcess(
        command, 0, kimi_output, "")
    _, host_wire_event, _, _ = asyncio.run(host_wire_agent._invoke_role(
        "reviewer", "review", SetupEnvironment(), 1))

    class KimiWireEnvironment(SetupEnvironment):
        async def exec(self, command, env=None, user=None):
            self.exec_calls.append((command, env, user))
            if command.startswith("cat -- "):
                return {"stdout": wire_text, "stderr": "", "returncode": 0}
            if command.startswith('export PATH="$HOME/.local/bin:$PATH"; kimi '):
                return {"stdout": kimi_output, "stderr": "", "returncode": 0}
            return await super().exec(command, env=env, user=user)

    container_wire_agent = agent_module.RelayHarnessAgent(
        tmp / "agent-kimi-container-wire", row=json.dumps(canonical[3]))
    container_wire_agent._container_home = Path("/home/benchmark")
    container_wire_environment = KimiWireEnvironment()
    _, container_wire_event, _, _ = asyncio.run(container_wire_agent._invoke_role(
        "worker", "work", container_wire_environment, 0))
    check("host Kimi usage comes from summed wire records",
          host_wire_event["input_tokens"] == 615 and host_wire_event["output_tokens"] == 15)
    check("in-container Kimi usage comes from summed wire records",
          container_wire_event["input_tokens"] == 615 and
          container_wire_event["output_tokens"] == 15 and any(
              command.startswith("cat -- /home/benchmark/.kimi-code/sessions/*/")
              for command, _, _ in container_wire_environment.exec_calls))

    missing_wire_agent = agent_module.RelayHarnessAgent(
        tmp / "agent-kimi-missing-wire", row=json.dumps(canonical[3]))
    missing_wire_agent._subprocess_run = lambda command, prompt: subprocess.CompletedProcess(
        command, 0, json.dumps({"role": "assistant", "content": "answer"}), "")
    _, missing_wire_event, _, _ = asyncio.run(missing_wire_agent._invoke_role(
        "reviewer", "review", SetupEnvironment(), 1))
    check("Kimi usage stays null without a resume hint",
          missing_wire_event["input_tokens"] is None and
          missing_wire_event["output_tokens"] is None)
    agent_module.HOST_HOME = setup_home

    async def exercise_prepared_subagent():
        agent, environment = await prepare(canonical[2], "subagent")
        agent._subprocess_run = lambda command, prompt: subprocess.CompletedProcess(
            command, 0, 'PASS\n{"usage":{"input_tokens":7,"output_tokens":3}}', "")
        context = agent_module.AgentContext()
        await agent.run("implement task", environment, context)
        return agent, environment, context

    subagent, subagent_environment, subagent_context = asyncio.run(
        exercise_prepared_subagent())
    claude_execs = [call for call in subagent_environment.exec_calls if "claude -p" in call[0]]
    check("subagent setup installs Claude exactly once for both in-container roles",
          [(vendor, model) for vendor, _, model in subagent_environment.installs] ==
          [("claude", canonical[2]["worker"]["model"])])
    check("every in-container Claude role invocation receives OAuth env",
          len(claude_execs) >= 2 and all(
              isinstance(env, dict) and env.get("CLAUDE_CODE_OAUTH_TOKEN") == setup_token
              for _, env, _ in claude_execs))
    check("every in-container Claude role uses the sandbox local-bin locator",
          all(command.startswith('export PATH="$HOME/.local/bin:$PATH"; export IS_SANDBOX=1; ')
              for command, _, _ in claude_execs))
    retained_role_evidence = "".join(
        path.read_text() for path in subagent.logs_dir.rglob("*") if path.is_file())
    check("Claude OAuth token is absent from role evidence",
          setup_token not in retained_role_evidence and
          setup_token not in json.dumps(subagent_context.metadata))

    class FailingRoleEnvironment(SetupEnvironment):
        async def exec(self, command, env=None, user=None):
            if "claude -p" in command:
                raise RuntimeError("in-container invocation failed with " + repr(env))
            return await super().exec(command, env=env, user=user)

    async def failing_invocation():
        agent = agent_module.RelayHarnessAgent(
            tmp / "setup-agent-failing-role", row=json.dumps(canonical[2]))
        environment = FailingRoleEnvironment()
        await agent.setup(environment)
        try:
            await agent.run("implement task", environment, agent_module.AgentContext())
        except RuntimeError as exc:
            return str(exc)
        return ""

    invocation_error = asyncio.run(failing_invocation())
    check("Claude OAuth token is absent from invocation exceptions",
          invocation_error and setup_token not in invocation_error)

    missing_home = tmp / "missing-setup-host-home"
    agent_module.HOST_HOME = missing_home

    async def missing_credential():
        agent = agent_module.RelayHarnessAgent(
            tmp / "setup-agent-missing", row=json.dumps(canonical[0]))
        environment = SetupEnvironment()
        try:
            await agent.setup(environment)
        except RuntimeError as exc:
            return str(exc), environment
        return "", environment

    missing_error, missing_environment = asyncio.run(missing_credential())
    check("missing needed credential fails setup before invocation",
          "codex" in missing_error and str(missing_home / ".codex" / "auth.json") in
          missing_error and not any("codex exec" in command
                                    for command, _, _ in missing_environment.exec_calls))
    agent_module.HOST_HOME = setup_home
    if saved_claude_token is not None:
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = saved_claude_token

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

    kimi_command_agent = agent_module.RelayHarnessAgent(
        tmp / "agent-kimi-command", row=json.dumps(canonical[3]))
    kimi_prompt = "benchmark prompt"
    expected_kimi_command = ["kimi", "-p", kimi_prompt, "-m",
                             canonical[3]["worker"]["model"], "--output-format", "stream-json"]
    check("Kimi role argv has no dash-y", all(
        kimi_command_agent._command(role, canonical[3][role], kimi_prompt) ==
        expected_kimi_command for role in ("worker", "reviewer")))

    retry_outcomes = {}

    def malformed_envelope(result, input_tokens, output_tokens, session_id=None):
        value = {
            "result": result,
            "terminal_reason": "malformed_tool_use_exhausted",
            "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens},
        }
        if session_id is not None:
            value["session_id"] = session_id
        return json.dumps(value)

    exhaust_agent = agent_module.RelayHarnessAgent(
        tmp / "agent-claude-retry-exhausted", row=json.dumps(canonical[0]))
    exhaust_calls = []

    def exhaust_cli(command, prompt):
        exhaust_calls.append((command, prompt))
        return subprocess.CompletedProcess(
            command, 1, malformed_envelope("malformed", 17, 4), "")

    exhaust_agent._subprocess_run = exhaust_cli
    try:
        asyncio.run(exhaust_agent._invoke_role("reviewer", "review", SetupEnvironment(), 2))
    except Exception as exc:
        retry_outcomes["retry exhaustion"] = exc
    else:
        retry_outcomes["retry exhaustion"] = None

    nonmalformed_agent = agent_module.RelayHarnessAgent(
        tmp / "agent-claude-nonmalformed", row=json.dumps(canonical[0]))
    nonmalformed_calls = []

    def nonmalformed_cli(command, prompt):
        nonmalformed_calls.append((command, prompt))
        return subprocess.CompletedProcess(command, 1, json.dumps({
            "result": "ordinary failure",
            "usage": {"input_tokens": 19, "output_tokens": 5},
        }), "")

    nonmalformed_agent._subprocess_run = nonmalformed_cli
    try:
        asyncio.run(nonmalformed_agent._invoke_role(
            "reviewer", "review", SetupEnvironment(), 3))
    except Exception as exc:
        retry_outcomes["non-malformed failure"] = exc
    else:
        retry_outcomes["non-malformed failure"] = None

    exhaust_usage = [json.loads(line) for line in exhaust_agent.usage_path.read_text().splitlines()]
    check("Claude malformed tool failure is terminal",
          isinstance(retry_outcomes["retry exhaustion"], RuntimeError) and
          len(exhaust_calls) >= 1 and len(exhaust_usage) >= 1)

    check("Claude provider failure is terminal",
          isinstance(retry_outcomes["non-malformed failure"], RuntimeError) and
          len(nonmalformed_calls) >= 1)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

if failures:
    print(f"{len(failures)} r102 benchmark test(s) failed", file=sys.stderr)
    raise SystemExit(1)
print("all r102 benchmark tests passed")
PY
