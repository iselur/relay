#!/usr/bin/env bash
# R71: scripts/models.json is the machine source of truth for role→model defaults, the reviewer
# failover pair, the CLI alias map, and the closed-world vendor map. This proves the dispatcher
# side fails CLOSED on any config problem, that an approval pin beats the config default (but
# never a cross-vendor violation), and that a role-model swap is a one-line config edit.
# DELIBERATELY not in tests/execution-policy.tsv (round-3 review, finding 1): a box-precondition
# entry would run at every launch from the sanitized grader tree, which has no venv — the skip
# below would then block ALL launches. Same default mode + skip contract as
# tests/dispatch_fail_closed.sh: no usable venv means SKIP LOUDLY, never a pass.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_model_config.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test needs the dispatcher venv; CI installs it)"
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
# Kimi vendor, slice 1: K3 is DECLARED (vendor + required CLI provider alias) while no role
# selects it — the future role swap stays a one-line config edit, and nothing resolves to kimi
# until its worker adapter (slice 2) and dispatcher wiring (slice 3) exist.
check("live config declares kimi-k3 as vendor kimi with its required CLI alias",
      live["vendor_map"].get("kimi-k3") == "kimi"
      and live["cli_aliases"].get("kimi-k3") == "kimi-code/k3")
check("no live role selects kimi-k3 (declaration is inert)",
      all(r["model"] != "kimi-k3" for r in live["roles"].values()))

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
check("vendor outside the closed vendor set refuses launch (exit 2)", load_result() == "exit2")
# Round-1 review, finding 3: a config that is not valid UTF-8 must refuse with exit 2, not an
# uncaught decode traceback.
scratch.write_bytes(b'\xff\xfe{ not utf-8 }')
check("non-UTF-8 config refuses launch (exit 2)", load_result() == "exit2")
# Round-1 review, finding 1: vendor RELATIONSHIPS are validated, not just vendor values. A known
# vendor prefix declared as the other vendor is the misdeclaration that would allow same-vendor
# review to pass — refused. And every model the config names must be declared in vendor_map.
bad = copy.deepcopy(good); bad["vendor_map"]["gpt-5.6-sol"] = "claude"
scratch.write_text(json.dumps(bad))
check("gpt model declared as claude vendor refuses launch (exit 2)", load_result() == "exit2")
bad = copy.deepcopy(good); bad["vendor_map"]["claude-opus-4-8"] = "codex"
scratch.write_text(json.dumps(bad))
check("claude model declared as codex vendor refuses launch (exit 2)", load_result() == "exit2")
bad = copy.deepcopy(good); bad["vendor_map"]["kimi-k3"] = "codex"
scratch.write_text(json.dumps(bad))
check("kimi model declared as codex vendor refuses launch (exit 2)", load_result() == "exit2")
bad = copy.deepcopy(good); bad["vendor_map"]["claude-opus-4-8"] = "kimi"
scratch.write_text(json.dumps(bad))
check("claude model declared as kimi vendor refuses launch (exit 2)", load_result() == "exit2")
# Kimi slice 3 (round-1 review): a kimi-vendor model MUST carry its CLI provider alias — the
# kimi CLI never accepts relay model ids, so an alias-less declaration is invalid config.
bad = copy.deepcopy(good); del bad["cli_aliases"]["kimi-k3"]
scratch.write_text(json.dumps(bad))
check("kimi-vendor model without its CLI alias refuses launch (exit 2)", load_result() == "exit2")
# Round-2 review: an IDENTITY alias would launder the raw relay id through the translation —
# the kimi alias must be DISTINCT from the model id.
bad = copy.deepcopy(good); bad["cli_aliases"]["kimi-k3"] = "kimi-k3"
scratch.write_text(json.dumps(bad))
check("kimi identity alias (raw id laundering) refuses launch (exit 2)", load_result() == "exit2")
bad = copy.deepcopy(good); del bad["vendor_map"][bad["roles"]["worker"]["model"]]
scratch.write_text(json.dumps(bad))
check("role model missing from vendor_map refuses launch (exit 2)", load_result() == "exit2")
bad = copy.deepcopy(good); del bad["vendor_map"][bad["reviewer_failover"]["fallback_model"]]
scratch.write_text(json.dumps(bad))
check("failover model missing from vendor_map refuses launch (exit 2)", load_result() == "exit2")
bad = copy.deepcopy(good); bad["cli_aliases"]["claude-fable-5"] = 7
scratch.write_text(json.dumps(bad))
check("non-string CLI alias refuses launch (exit 2)", load_result() == "exit2")
# Owner decision 2026-07-16: vendor pairing is config-authored, never policed — a same-vendor
# config VALIDATES. The mechanical rule that remains: the failover pair may not span vendors
# (the retry would switch CLIs mid-attempt).
sv = copy.deepcopy(good)
sv["roles"]["worker"]["model"] = "claude-sonnet-4-6"    # same vendor as the bound reviewer
scratch.write_text(json.dumps(sv))
check("same-vendor worker/bound-reviewer config VALIDATES (owner authority)",
      load_result() == "ok")
bad = copy.deepcopy(good)
bad["reviewer_failover"]["fallback_model"] = "gpt-5.6-sol"   # claude trigger, codex fallback
scratch.write_text(json.dumps(bad))
check("cross-vendor failover pair refuses launch (exit 2)", load_result() == "exit2")
# Round-2 review, finding 3: the models_check CLI itself (the shell consumers' path) must refuse
# non-UTF-8 bytes with exit 2, not a decode traceback.
import subprocess
scratch.write_bytes(b'\xff\xfe{ not utf-8 }')
cli = subprocess.run([sys.executable, "scripts/models_check.py", str(scratch),
                      "get", "roles.spec_author.model"], capture_output=True, text=True)
check("models_check CLI refuses non-UTF-8 config (exit 2, no value printed)",
      cli.returncode == 2 and cli.stdout == "" and "unreadable" in cli.stderr)
cli = subprocess.run([sys.executable, "scripts/models_check.py", str(scratch)],
                     capture_output=True, text=True)
check("models_check CLI validate-only mode also refuses non-UTF-8 (exit 2, silent stdout, "
      "stderr names the config PATH)",
      cli.returncode == 2 and cli.stdout == ""
      and "unreadable" in cli.stderr and str(scratch) in cli.stderr)

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
# Pins must be DECLARED models (authorship classification) and never the worker itself
# (self-review); vendor pairing is not policed (owner decision 2026-07-16).
pinned = d.resolve_launch_models(
    {"worker_model": "gpt-5.6-sol", "worker_reasoning_effort": "low",
     "reviewer_model": "claude-opus-4-8", "reviewer_effort": "medium"}, cfg)
check("cross-vendor approval pins beat config defaults",
      pinned["worker_model"] == "gpt-5.6-sol" and pinned["worker_effort"] == "low"
      and pinned["reviewer_model"] == "claude-opus-4-8" and pinned["reviewer_effort"] == "medium")
empty = d.resolve_launch_models({"worker_model": "", "reviewer_model": ""}, cfg)
check("empty-string pins fall back to config defaults (not trusted)",
      empty["worker_model"] == cfg["roles"]["worker"]["model"]
      and empty["reviewer_model"] == cfg["roles"]["bound_reviewer"]["model"])
check("even a pinned approval still freezes the config failover pair",
      pinned["reviewer_failover_trigger"] == cfg["reviewer_failover"]["trigger_model"]
      and pinned["reviewer_fallback_model"] == cfg["reviewer_failover"]["fallback_model"])

def resolve_result(approval):
    try:
        d.resolve_launch_models(approval, cfg); return "ok"
    except SystemExit as e:
        return f"exit{e.code}"

# Codex worker pins resolve; non-codex workers refuse until the worker adapter (R73 Job 2);
# unmapped pins refuse; same-MODEL refuses always.
check("codex worker pin resolves (config/approval authority)",
      d.resolve_launch_models({"worker_model": "gpt-5.6-sol",
                               "reviewer_model": "claude-fable-5"}, cfg)
      ["worker_model"] == "gpt-5.6-sol")
# R73 Job 3: the claude worker adapter exists (subagent mode) — a claude pin resolves and
# freezes the mode with the vendor; the fail-closed refusal for adapterless vendors is kept by
# the unmapped-model cases below (vendor_map is the closed world).
r_claude = d.resolve_launch_models({"worker_model": "claude-sonnet-4-6"}, cfg)
check("claude worker pin resolves and freezes worker_mode=subagent (R73 Job 3)",
      r_claude["worker_vendor"] == "claude" and r_claude["worker_mode"] == "subagent")
check("pinning an unmapped worker model refuses launch (exit 2)",
      resolve_result({"worker_model": "mystery-model-9"}) == "exit2")
check("pinning an unmapped reviewer model refuses launch (exit 2)",
      resolve_result({"reviewer_model": "mystery-model-9"}) == "exit2")
# Kimi slice 2: KimiWorker is registered, so a kimi worker pin RESOLVES and freezes truthful
# vendor+mode (deliberately flipping the slice-1 refusal). Slice 3 wired the dispatcher
# (KNOWN_VENDORS, runtime resolver, argv plumbing); launch still requires the isolation gate
# (tests/kimi_worker_isolation.sh, slice 4) before any kimi worker actually runs.
r_kimi = d.resolve_launch_models({"worker_model": "kimi-k3"}, cfg)
check("kimi worker pin resolves and freezes worker_vendor=kimi, worker_mode=external-cli",
      r_kimi["worker_vendor"] == "kimi" and r_kimi["worker_mode"] == "external-cli")
check("armed failover keeps the config fallback in the resolved fields",
      d.resolve_launch_models({"worker_model": "gpt-5.6-sol"}, cfg)
      ["reviewer_fallback_model"] == cfg["reviewer_failover"]["fallback_model"])
# "Nothing reviews its own work" — the one hard limit (CLAUDE.md rule 7): the resolved
# reviewer, or an ARMED fallback, equal to the worker model refuses unconditionally.
check("same-model reviewer==worker refuses launch (exit 2)",
      resolve_result({"worker_model": "claude-fable-5"}) == "exit2")
check("same-model pinned both ways refuses launch (exit 2)",
      resolve_result({"worker_model": "gpt-5.6-sol",
                      "reviewer_model": "gpt-5.6-sol"}) == "exit2")
check("armed fallback equal to the worker refuses launch (exit 2)",
      resolve_result({"worker_model": "claude-opus-4-8"}) == "exit2")
check("same-vendor different-model pairing resolves (the falsifier shape)",
      d.resolve_launch_models({"worker_model": "gpt-5.6-luna",
                               "reviewer_model": "gpt-5.6-sol"}, cfg)
      ["reviewer_model"] == "gpt-5.6-sol")
# R73 round-1 review (blocking): an alias targeting another declared model must refuse at
# validation (alias masquerade), and resolution compares alias-resolved EFFECTIVE models.
mc_spec = importlib.util.spec_from_file_location("mc", "scripts/models_check.py")
mc = importlib.util.module_from_spec(mc_spec); mc_spec.loader.exec_module(mc)
masq = json.loads(json.dumps(good))
masq["cli_aliases"]["gpt-5.6-sol"] = "gpt-5.6-luna"
check("alias targeting another declared model refuses validation",
      any("targets another declared model" in e for e in mc.validate(masq)))
alias_cfg = json.loads(json.dumps(cfg))
alias_cfg["cli_aliases"] = {**alias_cfg.get("cli_aliases", {}), "gpt-5.6-sol": "gpt-5.6-luna"}
def resolve_with(approval, c):
    try:
        d.resolve_launch_models(approval, c); return "ok"
    except SystemExit as e:
        return f"exit{e.code}"
check("alias-resolved effective self-review refuses launch (exit 2)",
      resolve_with({"worker_model": "gpt-5.6-luna", "reviewer_model": "gpt-5.6-sol"},
                   alias_cfg) == "exit2")

# Alias map semantics: exact translation for listed ids, pass-through for everything else.
aliases = cfg["cli_aliases"]
check("listed model id translates to its CLI alias",
      aliases.get("claude-fable-5", "claude-fable-5") == "fable")
check("kimi-k3 translates to the CLI's provider alias (probe A: the id the kimi CLI accepts)",
      aliases.get("kimi-k3", "kimi-k3") == "kimi-code/k3")
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
