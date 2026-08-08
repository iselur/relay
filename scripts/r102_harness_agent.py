"""Harbor custom agent for the R102 benchmark-only harness loop."""

import asyncio
import importlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time

from harbor.agents.base import BaseAgent
from harbor.models.agent.context import AgentContext


HOST_HOME = Path(os.environ.get("R102_HOST_HOME", Path.home()))
INSTALLED_AGENTS = {
    "codex": ("harbor.agents.installed.codex", "Codex"),
    "claude": ("harbor.agents.installed.claude_code", "ClaudeCode"),
    "kimi": ("harbor.agents.installed.kimi_cli", "KimiCli"),
}


class RelayHarnessAgent(BaseAgent):
    def __init__(self, logs_dir, model_name=None, logger=None, mcp_servers=None,
                 skills_dir=None, *args, extra_env=None, row=None, **kwargs):
        super().__init__(logs_dir, model_name, logger, mcp_servers, skills_dir, *args,
                         extra_env=extra_env, **kwargs)
        if isinstance(row, dict):
            parsed = row
        elif isinstance(row, str):
            try:
                parsed = json.loads(row)
            except json.JSONDecodeError as exc:
                raise ValueError(f"invalid row agent kwarg: {exc}") from exc
        else:
            raise ValueError("RelayHarnessAgent requires agent kwarg row=<json>")
        if not isinstance(parsed, dict) or parsed.get("kind") != "harness":
            raise ValueError("row agent kwarg must describe a harness row")
        self.row = parsed
        self.logs_dir = Path(logs_dir)
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        self.usage_path = self.logs_dir / "usage.jsonl"
        self._claude_oauth_token = None

    @staticmethod
    def name():
        return "r102-relay-harness"

    @staticmethod
    def version():
        return "1"

    async def setup(self, environment):
        roles = ["worker"]
        if self.row.get("worker_mode") == "subagent":
            roles.append("orchestrator")
        bindings = {}
        for role in roles:
            binding = self.row[role]
            bindings.setdefault(binding["vendor"], binding)

        for vendor, binding in bindings.items():
            module_name, class_name = INSTALLED_AGENTS[vendor]
            installed_class = getattr(importlib.import_module(module_name), class_name)
            installed = installed_class(
                self.logs_dir / ("installed-" + vendor), model_name=binding["model"]
            )
            await installed.setup(environment)

        home = None
        if "codex" in bindings or "kimi" in bindings:
            result = environment.exec('printf %s "$HOME"')
            if hasattr(result, "__await__"):
                result = await result
            stdout, _, code = self._result_text(result)
            home = stdout.strip()
            if code != 0 or not home:
                raise RuntimeError("cannot resolve container user home")

        if "codex" in bindings:
            source = HOST_HOME / ".codex" / "auth.json"
            if not source.is_file():
                raise RuntimeError(f"missing codex credential: {source}")
            target_dir = Path(home) / ".codex"
            await self._exec_setup(environment, f"mkdir -p {shlex.quote(str(target_dir))}",
                                   user="root")
            await environment.upload_file(source, target_dir / "auth.json")
            await self._chown(environment, target_dir)

        if "kimi" in bindings:
            source = HOST_HOME / ".kimi-code" / "credentials"
            if not source.is_dir():
                raise RuntimeError(f"missing kimi credential: {source}")
            target = Path(home) / ".kimi-code" / "credentials"
            await environment.upload_dir(source, target)
            await self._chown(environment, target)
            config = HOST_HOME / ".kimi-code" / "config.toml"
            if config.is_file():
                config_target = Path(home) / ".kimi-code" / "config.toml"
                await environment.upload_file(config, config_target)
                await self._chown(environment, config_target)

        if "claude" in bindings:
            token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
            source = HOST_HOME / ".claude" / ".credentials.json"
            if not token:
                try:
                    value = json.loads(source.read_bytes())
                    token = value["claudeAiOauth"]["accessToken"]
                except (OSError, UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError):
                    token = None
            if not isinstance(token, str) or not token:
                raise RuntimeError(f"missing claude credential: {source}")
            self._claude_oauth_token = token

    async def _exec_setup(self, environment, command, **kwargs):
        result = environment.exec(command, **kwargs)
        if hasattr(result, "__await__"):
            result = await result
        return result

    async def _chown(self, environment, path):
        user = getattr(environment, "default_user", None)
        if user:
            await self._exec_setup(
                environment,
                f"chown -R {shlex.quote(user)} {shlex.quote(str(path))}",
                user="root",
            )

    def _command(self, role, binding, prompt, session_id=None):
        vendor = binding["vendor"]
        model = binding["model"]
        effort = binding["effort"]
        if vendor == "codex":
            sandbox = "danger-full-access" if role == "worker" else "read-only"
            return ["codex", "exec", "-m", model, "-c",
                    f"model_reasoning_effort={effort}", "--sandbox", sandbox,
                    "--skip-git-repo-check", "--json", "-"]
        if vendor == "claude":
            command = ["claude", "-p", "--output-format", "json", "--model", model,
                       "--effort", effort]
            if role == "worker":
                if self.row.get("worker_mode") == "subagent":
                    if not session_id:
                        raise RuntimeError("Claude orchestrator session id was not reported")
                    agents = json.dumps({
                        "r102-worker": {
                            "description": "Implements the benchmark worker brief",
                            "prompt": "Work only on the benchmark task and complete the brief.",
                            "tools": ["Read", "Grep", "Glob", "Bash", "Write", "Edit"],
                            "model": "inherit",
                        }
                    }, separators=(",", ":"))
                    command.extend(["--resume", session_id, "--agents", agents])
                return command + ["--permission-mode", "bypassPermissions"]
            safe_command = command + [
                "--safe-mode", "--tools", "", "--strict-mcp-config",
                "--disallowedTools", "Read", "Grep", "Glob",
                "Bash", "Write", "Edit", "NotebookEdit", "WebFetch", "WebSearch", "Task",
                "--permission-mode", "manual",
            ]
            if role != "orchestrator" or self.row.get("worker_mode") != "subagent":
                safe_command.append("--no-session-persistence")
            return safe_command
        if vendor == "kimi":
            command = ["kimi", "-p", prompt, "-m", model, "--output-format", "stream-json"]
            return command + (["-y"] if role == "worker" else [])
        raise ValueError(f"unsupported R102 vendor: {vendor}")

    def _subprocess_run(self, command, prompt):
        return subprocess.run(command, input=prompt, text=True, capture_output=True,
                              check=False)

    async def _environment_exec(self, environment, command, prompt, env=None):
        shell_command = shlex.join(command)
        if prompt is not None:
            shell_command = f"printf %s {shlex.quote(prompt)} | {shell_command}"
        locator = {
            "codex": "if [ -s ~/.nvm/nvm.sh ]; then . ~/.nvm/nvm.sh; fi; ",
            "claude": 'export PATH="$HOME/.local/bin:$PATH"; ',
            "kimi": 'export PATH="$HOME/.local/bin:$PATH"; ',
        }[command[0]]
        shell_command = locator + shell_command
        try:
            if env is None:
                result = environment.exec(shell_command)
            else:
                result = environment.exec(shell_command, env=env)
            if hasattr(result, "__await__"):
                result = await result
        except Exception:
            if env is not None:
                raise RuntimeError("in-container role invocation failed") from None
            raise
        return result

    @staticmethod
    def _result_text(result):
        if isinstance(result, str):
            return result, "", 0
        if isinstance(result, dict):
            return (str(result.get("stdout", "")), str(result.get("stderr", "")),
                    int(result.get("returncode", result.get("exit_code", 0))))
        stdout = getattr(result, "stdout", "")
        stderr = getattr(result, "stderr", "")
        code = getattr(result, "returncode", getattr(result, "exit_code", 0))
        return str(stdout or ""), str(stderr or ""), int(code or 0)

    @staticmethod
    def _tokens(text):
        input_keys = ("n_input_tokens", "input_tokens", "inputTokens", "prompt_tokens")
        output_keys = ("n_output_tokens", "output_tokens", "outputTokens", "completion_tokens")

        def valid(value):
            return isinstance(value, int) and not isinstance(value, bool) and value >= 0

        def find(value):
            if not isinstance(value, dict):
                return None, None
            input_tokens = next((value[key] for key in input_keys if valid(value.get(key))), None)
            output_tokens = next((value[key] for key in output_keys if valid(value.get(key))), None)
            if input_tokens is not None and output_tokens is not None:
                return input_tokens, output_tokens
            for child in value.values():
                if isinstance(child, dict):
                    found = find(child)
                    if found != (None, None):
                        return found
            return input_tokens, output_tokens

        for line in reversed(text.splitlines()):
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            found = find(value)
            if found != (None, None):
                return found
        return None, None

    @staticmethod
    def _answer(vendor, output):
        if vendor == "claude":
            try:
                envelope = json.loads(output)
                if isinstance(envelope, dict) and isinstance(envelope.get("result"), str):
                    return envelope["result"]
            except json.JSONDecodeError:
                pass
        answer = None
        for line in output.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if vendor == "kimi" and isinstance(event, dict) and event.get("role") == "assistant":
                if isinstance(event.get("content"), str):
                    answer = event["content"]
            if vendor == "codex" and isinstance(event, dict):
                item = event.get("item")
                if isinstance(item, dict) and item.get("type") == "agent_message" and isinstance(
                        item.get("text"), str):
                    answer = item["text"]
        return answer if answer is not None else output

    @staticmethod
    def _session_id(output):
        try:
            envelope = json.loads(output)
        except json.JSONDecodeError:
            return None
        value = envelope.get("session_id") if isinstance(envelope, dict) else None
        return value if isinstance(value, str) and value else None

    def _append_usage(self, role, binding, input_tokens, output_tokens, wall_s, round_number):
        event = {
            "role": role,
            "vendor": binding["vendor"],
            "model": binding["model"],
            "effort": binding["effort"],
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "wall_s": wall_s,
            "round": round_number,
        }
        with self.usage_path.open("a") as sink:
            sink.write(json.dumps(event, separators=(",", ":")) + "\n")
        return event

    async def _invoke_role(self, role, prompt, environment, round_number,
                           use_environment=False, session_id=None):
        binding = self.row[role]
        command = self._command(role, binding, prompt, session_id=session_id)
        started = time.monotonic()
        if role == "worker" or use_environment:
            stdin_prompt = None if binding["vendor"] == "kimi" else prompt
            role_env = None
            if binding["vendor"] == "claude" and self._claude_oauth_token is not None:
                role_env = {"CLAUDE_CODE_OAUTH_TOKEN": self._claude_oauth_token}
            result = await self._environment_exec(
                environment, command, stdin_prompt, env=role_env)
        else:
            result = await asyncio.to_thread(self._subprocess_run, command, prompt)
        wall_s = time.monotonic() - started
        stdout, stderr, code = self._result_text(result)
        log_path = self.logs_dir / f"{role}-round-{round_number}.log"
        log_path.write_text(stdout + ("\n[stderr]\n" + stderr if stderr else ""))
        input_tokens, output_tokens = self._tokens(stdout + "\n" + stderr)
        event = self._append_usage(role, binding, input_tokens, output_tokens, wall_s,
                                   round_number)
        if code != 0:
            raise RuntimeError(f"{role} invocation exited {code}; see {log_path.name}")
        return (self._answer(binding["vendor"], stdout), event, log_path,
                self._session_id(stdout))

    @staticmethod
    def _review_verdict(output):
        match = re.search(r"\b(PASS|REVISE)\b", output.upper())
        return match.group(1) if match else "REVISE"

    @staticmethod
    def _per_role(events):
        totals = {}
        for event in events:
            role = event["role"]
            current = totals.setdefault(role, {"input_tokens": 0, "output_tokens": 0})
            if isinstance(event["input_tokens"], int):
                current["input_tokens"] += event["input_tokens"]
            if isinstance(event["output_tokens"], int):
                current["output_tokens"] += event["output_tokens"]
        return totals

    async def run(self, instruction, environment, context):
        events = []
        orchestrator_prompt = (
            "Produce a concise worker brief for this benchmark task. Preserve the task's "
            "requirements and limit the brief to implementation inside the task environment.\n\n"
            + instruction
        )
        subagent_mode = self.row.get("worker_mode") == "subagent"
        worker_brief, event, orchestrator_log, session_id = await self._invoke_role(
            "orchestrator", orchestrator_prompt, environment, 0,
            use_environment=subagent_mode)
        events.append(event)

        worker_prompt = worker_brief
        if subagent_mode:
            worker_prompt = (
                "Delegate the brief below to the r102-worker subagent and return its outcome.\n\n"
                + worker_brief
            )
        worker_outcome, event, _, _ = await self._invoke_role(
            "worker", worker_prompt, environment, 0, session_id=session_id)
        events.append(event)

        review_rounds = 0
        reviewer = self.row.get("reviewer")
        if reviewer is not None:
            for round_number in range(1, self.row["review_rounds_max"] + 1):
                review_prompt = (
                    "Review the benchmark worker outcome against the original task. Begin with "
                    "PASS or REVISE, then give only material findings.\n\nTASK:\n"
                    + instruction + "\n\nWORKER OUTCOME:\n" + worker_outcome
                )
                review, event, _, _ = await self._invoke_role(
                    "reviewer", review_prompt, environment, round_number)
                events.append(event)
                review_rounds = round_number
                if self._review_verdict(review) == "PASS":
                    break
                remediation_prompt = (
                    "Remediate the review findings in the benchmark task environment.\n\n"
                    "WORKER BRIEF:\n" + worker_brief + "\n\nFINDINGS:\n" + review
                )
                worker_outcome, event, _, _ = await self._invoke_role(
                    "worker", remediation_prompt, environment, round_number,
                    session_id=session_id)
                events.append(event)

        input_total = sum(event["input_tokens"] for event in events
                          if isinstance(event["input_tokens"], int))
        output_total = sum(event["output_tokens"] for event in events
                           if isinstance(event["output_tokens"], int))
        context.n_input_tokens = input_total
        context.n_output_tokens = output_total
        quality_only = self.row.get("worker_mode") == "subagent"
        r102 = {
            "config": self.row["name"],
            "review_rounds": review_rounds,
            "per_role": self._per_role(events),
            "quality_only": quality_only,
            "orchestrator_evidence": {
                "vendor": self.row["orchestrator"]["vendor"],
                "model": self.row["orchestrator"]["model"],
                "log": orchestrator_log.name,
            },
        }
        if quality_only:
            r102["attribution_probe"] = (
                "Claude subagent session exposes aggregate session usage, not a trustworthy "
                "orchestrator/child split"
            )
        if context.metadata is None:
            context.metadata = {}
        context.metadata["r102"] = r102
        return context
