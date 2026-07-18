#!/usr/bin/env bash
# R71: scripts/models.json is the machine source of truth for role→model defaults, the CLI
# alias map, and the closed-world vendor map. This proves the dispatcher side fails CLOSED on
# any config problem, that an approval pin beats the config default, and that a role-model
# swap is a one-line config edit.
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
check("live vendor_patterns classifies every named role model to a known vendor without ambiguity",
      all(d.load_models_check().classify(r["model"], live) in ("claude", "codex", "kimi")
          for r in live["roles"].values()))
# Kimi vendor: kimi-k3 classifies as kimi by name pattern and carries its required CLI alias
# while no role selects it — the future role swap stays a one-line config edit, and nothing
# resolves to kimi until the owner assigns a kimi role model.
check("live vendor_patterns classifies kimi-k3 as kimi and its CLI alias is declared",
      d.load_models_check().classify("kimi-k3", live) == "kimi"
      and live["cli_aliases"].get("kimi-k3") == "kimi-code/k3")
check("no live role selects kimi-k3 (vendor_patterns-era: kimi model available but inert)",
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
for section in ("roles", "cli_aliases", "vendor_patterns"):
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
bad = copy.deepcopy(good); bad["vendor_patterns"]["other-vendor"] = ["oth"]
scratch.write_text(json.dumps(bad))
check("vendor_patterns key outside the closed vendor set refuses launch (exit 2)", load_result() == "exit2")
# Round-1 review, finding 3: a config that is not valid UTF-8 must refuse with exit 2, not an
# uncaught decode traceback.
scratch.write_bytes(b'\xff\xfe{ not utf-8 }')
check("non-UTF-8 config refuses launch (exit 2)", load_result() == "exit2")
# Owner decision 2026-07-18: vendor PATTERNS replace the per-model registry. PREFIX_RULES are
# gone; the remaining relationship guard is ambiguity: a role model id matching two vendors'
# patterns simultaneously fails closed, preventing any model from being silently mis-routed.
bad = copy.deepcopy(good); bad["vendor_patterns"]["kimi"] = ["kimi", "opus"]
# "claude-opus-4-8" is a named role model; it contains "claude" (matches vendor "claude") AND
# "opus" (now matches vendor "kimi") — two distinct vendor hits, so classify() raises ValueError
# and validate() records the error.
scratch.write_text(json.dumps(bad))
check("model id matching two vendor patterns is ambiguous, refuses launch (exit 2)", load_result() == "exit2")
# Kimi slice 3 (round-1 review): a kimi-vendor ROLE MODEL must carry its CLI provider alias —
# the kimi CLI never accepts relay model ids. The alias requirement triggers for named_models
# (role models), so test with a config that assigns the kimi model to a role.
kimi_cfg = copy.deepcopy(good); kimi_cfg["roles"]["spec_author"]["model"] = "kimi-k3"
bad = copy.deepcopy(kimi_cfg); del bad["cli_aliases"]["kimi-k3"]
scratch.write_text(json.dumps(bad))
check("kimi-vendor role model without its CLI alias refuses launch (exit 2)", load_result() == "exit2")
# Round-2 review: an IDENTITY alias would launder the raw relay id through the translation —
# the kimi alias must be DISTINCT from the model id.
bad = copy.deepcopy(kimi_cfg); bad["cli_aliases"]["kimi-k3"] = "kimi-k3"
scratch.write_text(json.dumps(bad))
check("kimi identity alias (raw id laundering) refuses launch (exit 2)", load_result() == "exit2")
# Owner decision 2026-07-18: unrecognized role models fall through to the sandboxed default
# (codex), never refused — adding a new model costs no config edit.
swapped_unknown = copy.deepcopy(good)
swapped_unknown["roles"]["worker"]["model"] = "some-unknown-model"
scratch.write_text(json.dumps(swapped_unknown))
check("role model absent from vendor_patterns defaults to codex (sandboxed, config VALIDATES)",
      load_result() == "ok")
bad = copy.deepcopy(good); bad["cli_aliases"]["claude-fable-5"] = 7
scratch.write_text(json.dumps(bad))
check("non-string CLI alias refuses launch (exit 2)", load_result() == "exit2")
# Owner decision 2026-07-16: vendor pairing is config-authored, never policed — a same-vendor
# config VALIDATES.
sv = copy.deepcopy(good)
sv["roles"]["worker"]["model"] = "claude-sonnet-4-6"    # same vendor as the bound reviewer
scratch.write_text(json.dumps(sv))
check("same-vendor worker/bound-reviewer config VALIDATES (owner authority)",
      load_result() == "ok")
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
# omits (or empties) a field; a non-empty approval pin wins; aliases always frozen.
r = d.resolve_launch_models({}, cfg)
check("approval omitting models gets config defaults",
      r["worker_model"] == cfg["roles"]["worker"]["model"]
      and r["worker_effort"] == cfg["roles"]["worker"]["effort"]
      and r["reviewer_model"] == cfg["roles"]["bound_reviewer"]["model"]
      and r["reviewer_effort"] == cfg["roles"]["bound_reviewer"]["effort"])
check("resolver freezes the alias map from config",
      r["cli_aliases"] == cfg["cli_aliases"])
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

def resolve_result(approval):
    try:
        d.resolve_launch_models(approval, cfg); return "ok"
    except SystemExit as e:
        return f"exit{e.code}"

# Codex worker pins resolve; adapterless vendors still refuse at resolution; unrecognized models
# default to the sandboxed vendor (codex) rather than being refused (owner decision 2026-07-18).
check("codex worker pin resolves (config/approval authority)",
      d.resolve_launch_models({"worker_model": "gpt-5.6-sol",
                               "reviewer_model": "claude-fable-5"}, cfg)
      ["worker_model"] == "gpt-5.6-sol")
# R73 Job 3: the claude worker adapter exists (subagent mode) — a claude pin resolves and
# freezes the mode with the vendor; the fail-closed refusal for adapterless vendors is preserved
# (worker_mode raises for unknown vendors, adapter gate runs at resolution).
r_claude = d.resolve_launch_models({"worker_model": "claude-sonnet-4-6"}, cfg)
check("claude worker pin resolves and freezes worker_mode=subagent (R73 Job 3)",
      r_claude["worker_vendor"] == "claude" and r_claude["worker_mode"] == "subagent")
# Owner decision 2026-07-18: unrecognized models default to codex (sandboxed) rather than refused.
r_mystery = d.resolve_launch_models({"worker_model": "mystery-model-9"}, cfg)
check("unrecognized worker model defaults to codex vendor (sandboxed, not refused)",
      r_mystery["worker_vendor"] == "codex" and r_mystery["worker_model"] == "mystery-model-9")
r_mystery_rev = d.resolve_launch_models({"reviewer_model": "mystery-model-9"}, cfg)
check("unrecognized reviewer model defaults to codex vendor (no closed-world refusal)",
      r_mystery_rev["reviewer_vendor"] == "codex" and r_mystery_rev["reviewer_model"] == "mystery-model-9")
# Kimi slice 2: KimiWorker is registered, so a kimi worker pin RESOLVES and freezes truthful
# vendor+mode (deliberately flipping the slice-1 refusal). Slice 3 wired the dispatcher
# (KNOWN_VENDORS, runtime resolver, argv plumbing); launch still requires the isolation gate
# (tests/kimi_worker_isolation.sh, slice 4) before any kimi worker actually runs.
r_kimi = d.resolve_launch_models({"worker_model": "kimi-k3"}, cfg)
check("kimi worker pin resolves and freezes worker_vendor=kimi, worker_mode=external-cli",
      r_kimi["worker_vendor"] == "kimi" and r_kimi["worker_mode"] == "external-cli")
# Owner decision 2026-07-18: "nothing reviews its own work" (CLAUDE.md rule 7) binds the AGENT,
# not the weights — the reviewer is a separate process with its own prompt and only spec, diff
# and evidence. Worker and reviewer on the same model resolve; model choice is the owner's.
r_same = d.resolve_launch_models({"worker_model": "gpt-5.6-sol",
                                  "reviewer_model": "gpt-5.6-sol"}, cfg)
check("same-model reviewer==worker resolves (owner decision 2026-07-18)",
      r_same["worker_model"] == "gpt-5.6-sol" and r_same["reviewer_model"] == "gpt-5.6-sol")
check("same-vendor different-model pairing resolves (the falsifier shape)",
      d.resolve_launch_models({"worker_model": "gpt-5.6-luna",
                               "reviewer_model": "gpt-5.6-sol"}, cfg)
      ["reviewer_model"] == "gpt-5.6-sol")
# R73 round-1 review (blocking): an alias targeting another declared model must refuse at
# validation — aliases map a model id to its vendor-CLI name, never to another model.
mc_spec = importlib.util.spec_from_file_location("mc", "scripts/models_check.py")
mc = importlib.util.module_from_spec(mc_spec); mc_spec.loader.exec_module(mc)
masq = json.loads(json.dumps(good))
masq["cli_aliases"]["gpt-5.6-sol"] = "gpt-5.6-luna"
check("alias targeting another declared model refuses validation",
      any("targets another declared model" in e for e in mc.validate(masq)))

# Alias map semantics: exact translation for listed ids, pass-through for everything else.
aliases = cfg["cli_aliases"]
check("listed model id translates to its CLI alias",
      aliases.get("claude-fable-5", "claude-fable-5") == "fable")
check("kimi-k3 translates to the CLI's provider alias (probe A: the id the kimi CLI accepts)",
      aliases.get("kimi-k3", "kimi-k3") == "kimi-code/k3")
check("unlisted model id passes through unchanged",
      aliases.get("some-new-model", "some-new-model") == "some-new-model")

# vendor_patterns: classify() by name substring; an unknown model defaults to the sandboxed vendor.
mc_for_vp = d.load_models_check()
check("vendor_patterns classifies known models by substring match",
      mc_for_vp.classify("gpt-5.6-luna", cfg) == "codex"
      and mc_for_vp.classify("gpt-5.6-sol", cfg) == "codex"
      and mc_for_vp.classify("claude-fable-5", cfg) == "claude"
      and mc_for_vp.classify("claude-opus-4-8", cfg) == "claude"
      and mc_for_vp.classify("claude-sonnet-4-6", cfg) == "claude")
check("unknown model defaults to codex (sandboxed DEFAULT_VENDOR, not refused)",
      mc_for_vp.classify("some-hypothetical-model", cfg) == "codex")

# The point of R71: a role-model swap is ONE config value edit — no code change anywhere.
# No vendor_patterns entry needed: gpt-7-hypothetical matches no patterns → DEFAULT_VENDOR (codex).
swapped = copy.deepcopy(good)
swapped["roles"]["worker"]["model"] = "gpt-7-hypothetical"
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
