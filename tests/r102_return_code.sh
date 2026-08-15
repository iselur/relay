#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

export PYTHONDONTWRITEBYTECODE=1
python3 -B - <<'PY'
import asyncio
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import tempfile
import sys

root = Path.cwd()
fake = Path(tempfile.mkdtemp(prefix="r102-return-code-"))
for relative, body in {
    "harbor/__init__.py": "",
    "harbor/agents/__init__.py": "",
    "harbor/agents/base.py": "class BaseAgent:\n    def __init__(self, *args, **kwargs):\n        pass\n",
    "harbor/models/__init__.py": "",
    "harbor/models/agent/__init__.py": "",
    "harbor/models/agent/context.py": "class AgentContext: pass\n",
}.items():
    path = fake / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
sys.path.insert(0, str(fake))
spec = importlib.util.spec_from_file_location(
    "r102_agent", root / "scripts" / "r102_harness_agent.py")
agent_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent_module)

def check(name, condition):
    if not condition:
        raise AssertionError(name)
agent = agent_module.RelayHarnessAgent(
    fake / "logs", row={"kind": "harness", "name": "fixture"})
dict_fallbacks = [({"returncode": 2}, 2), ({"exit_code": 3}, 3), ({}, 0)]
object_fallbacks = [(SimpleNamespace(returncode=2), 2),
                   (SimpleNamespace(exit_code=3), 3), (SimpleNamespace(), 0)]
for result, expected in dict_fallbacks:
    check("dict return-code fallback", agent._result_text(result)[2] == expected)
for result, expected in object_fallbacks:
    check("object return-code fallback", agent._result_text(result)[2] == expected)
check("dict return_code wins", agent._result_text({
    "return_code": 7, "returncode": 8, "exit_code": 9})[2] == 7)
check("object return_code wins", agent._result_text(SimpleNamespace(
    return_code=7, returncode=8, exit_code=9))[2] == 7)
check("stdout and stderr convert", agent._result_text({
    "stdout": 123, "stderr": 456, "return_code": 0})[:2] == ("123", "456"))
check("string result stays successful", agent._result_text("plain output") ==
      ("plain output", "", 0))
class Environment:
    def __init__(self):
        self.calls = []

    async def exec(self, command, **kwargs):
        self.calls.append((command, kwargs))
        return {"stdout": "worker output", "stderr": "worker error", "return_code": 7}


async def invoke_worker():
    worker = agent_module.RelayHarnessAgent(
        fake / "worker-logs",
        row={"kind": "harness", "name": "fixture", "worker": {
            "vendor": "codex", "model": "fixture", "effort": "high"}})
    environment = Environment()
    outcome = None
    try:
        outcome = await worker._invoke_role("worker", "work", environment, 0)
    except RuntimeError as exc:
        return outcome, str(exc), environment.calls
    return outcome, "", environment.calls
outcome, error, calls = asyncio.run(invoke_worker())
check("worker return_code failure raises", outcome is None and
      "worker invocation exited 7" in error and len(calls) == 1)
PY
