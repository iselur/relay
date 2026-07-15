#!/usr/bin/env bash
# R71: scripts/models.json is the machine source of truth for role→model defaults, the reviewer
# failover pair, the CLI alias map, and the closed-world vendor map. This proves the dispatcher
# side fails CLOSED on any config problem, that an approval pin beats the config default, and
# that a role-model swap is a one-line config edit — no Python or shell change.
# Same box-only skip contract as tests/dispatch_fail_closed.sh: no venv on CI; SKIP LOUDLY there.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_model_config.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test runs on the box only, not CI)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import copy, hashlib, importlib.util, json, pathlib, sys, tempfile

spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

# The LIVE tracked config must load — this file being valid is a box precondition for every launch.
live_path = d.MODEL_CONFIG
live_bytes = live_path.read_bytes()
live = d.load_model_config()
check("live scripts/models.json loads and schema-validates", isinstance(live, dict))
check("live config carries all six rev-4 roles",
      set(live["roles"]) == {"orchestrator", "spec_author", "utility_subagent", "worker",
                             "bound_reviewer", "orchestrator_artifact_reviewer"})
check("live vendor_map covers every model named anywhere in the config",
      set(live["vendor_map"])
      >= ({r["model"] for r in live["roles"].values()}
          | {live["reviewer_failover"]["trigger_model"],
             live["reviewer_failover"]["fallback_model"]}))

# All remaining cases run against a scratch copy; the live file must come out untouched.
tmp = pathlib.Path(tempfile.mkdtemp())
scratch = tmp / "models.json"
d.MODEL_CONFIG = scratch

def load_result():
    """'ok' when the config loads, 'exit<code>' when load_model_config() dies."""
    try:
        d.load_model_config(); return "ok"
    except SystemExit as e:
        return f"exit{e.code}"

good = json.loads(live_bytes)

# Fail closed: missing, unreadable-as-JSON, wrong version, and each required piece removed in turn.
check("missing config refuses launch (exit 2)", load_result() == "exit2")
scratch.write_text("{truncated")
check("malformed JSON refuses launch (exit 2)", load_result() == "exit2")
bad = copy.deepcopy(good); bad["schema_version"] = "2"
scratch.write_text(json.dumps(bad))
check("unsupported schema_version refuses launch (exit 2)", load_result() == "exit2")
for section in ("roles", "reviewer_failover", "cli_aliases", "vendor_map"):
    bad = copy.deepcopy(good); del bad[section]
    scratch.write_text(json.dumps(bad))
    check(f"config without {section} refuses launch (exit 2)", load_result() == "exit2")
for role in good["roles"]:
    bad = copy.deepcopy(good); del bad["roles"][role]
    scratch.write_text(json.dumps(bad))
    check(f"config without roles.{role} refuses launch (exit 2)", load_result() == "exit2")
bad = copy.deepcopy(good); bad["roles"]["worker"]["model"] = ""
scratch.write_text(json.dumps(bad))
check("empty role model refuses launch (exit 2)", load_result() == "exit2")
bad = copy.deepcopy(good); bad["vendor_map"]["some-model"] = "other-vendor"
scratch.write_text(json.dumps(bad))
check("vendor outside claude|codex refuses launch (exit 2)", load_result() == "exit2")

scratch.write_text(json.dumps(good))
check("valid config loads cleanly", load_result() == "ok")
cfg = d.load_model_config()

# Precedence through the ONE resolver cmd_launch persists: config default when the approval
# omits (or empties) a field; a non-empty approval pin wins; failover pair + aliases always frozen.
r = d.resolve_launch_models({}, cfg)
check("approval omitting models gets config defaults",
      r["worker_model"] == cfg["roles"]["worker"]["model"]
      and r["worker_effort"] == cfg["roles"]["worker"]["effort"]
      and r["reviewer_model"] == cfg["roles"]["bound_reviewer"]["model"]
      and r["reviewer_effort"] == cfg["roles"]["bound_reviewer"]["effort"])
check("resolver freezes failover pair and alias map from config",
      r["reviewer_failover_trigger"] == cfg["reviewer_failover"]["trigger_model"]
      and r["reviewer_fallback_model"] == cfg["reviewer_failover"]["fallback_model"]
      and r["cli_aliases"] == cfg["cli_aliases"])
pinned = d.resolve_launch_models(
    {"worker_model": "pinned-worker", "worker_reasoning_effort": "low",
     "reviewer_model": "pinned-reviewer", "reviewer_effort": "medium"}, cfg)
check("approval pins beat config defaults",
      pinned["worker_model"] == "pinned-worker" and pinned["worker_effort"] == "low"
      and pinned["reviewer_model"] == "pinned-reviewer" and pinned["reviewer_effort"] == "medium")
empty = d.resolve_launch_models({"worker_model": "", "reviewer_model": ""}, cfg)
check("empty-string pins fall back to config defaults (not trusted)",
      empty["worker_model"] == cfg["roles"]["worker"]["model"]
      and empty["reviewer_model"] == cfg["roles"]["bound_reviewer"]["model"])
check("even a pinned approval still freezes the config failover pair",
      pinned["reviewer_failover_trigger"] == cfg["reviewer_failover"]["trigger_model"]
      and pinned["reviewer_fallback_model"] == cfg["reviewer_failover"]["fallback_model"])

# Alias map semantics: exact translation for listed ids, pass-through for everything else.
aliases = cfg["cli_aliases"]
check("listed model id translates to its CLI alias",
      aliases.get("claude-fable-5", "claude-fable-5") == "fable")
check("unlisted model id passes through unchanged",
      aliases.get("some-new-model", "some-new-model") == "some-new-model")

# Closed-world vendor map: known ids map exactly; an absent id is absent, never guessed.
vm = cfg["vendor_map"]
check("vendor_map classifies known ids exactly",
      vm.get("gpt-5.6-luna") == "codex" and vm.get("gpt-5.6-sol") == "codex"
      and vm.get("claude-fable-5") == "claude" and vm.get("claude-opus-4-8") == "claude"
      and vm.get("claude-sonnet-4-6") == "claude")
check("unknown model is absent from vendor_map (not guessed)",
      vm.get("some-hypothetical-model") is None)

# The point of R71: a role-model swap is ONE config value edit — no code change anywhere.
swapped = copy.deepcopy(good)
swapped["roles"]["worker"]["model"] = "gpt-7-hypothetical"
swapped["vendor_map"]["gpt-7-hypothetical"] = "codex"
scratch.write_text(json.dumps(swapped))
r_swapped = d.resolve_launch_models({}, d.load_model_config())
check("a one-line worker-model swap changes default resolution with no code edit",
      r_swapped["worker_model"] == "gpt-7-hypothetical")

# ...and none of the scratch work touched the live tracked config.
d.MODEL_CONFIG = live_path
check("live scripts/models.json is byte-identical after the test",
      hashlib.sha256(live_path.read_bytes()).hexdigest()
      == hashlib.sha256(live_bytes).hexdigest())

sys.exit(1 if fails else 0)
PY
echo "PASS dispatch_model_config.sh"
