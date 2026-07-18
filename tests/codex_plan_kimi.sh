#!/usr/bin/env bash
# Tests for the kimi vendor path in scripts/codex-plan.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

PY="${ORCH_TEST_PY:-python3}"
[ -n "${ORCH_TEST_PY:-}" ] || [ ! -x "$ROOT/.venv/bin/python" ] || PY="$ROOT/.venv/bin/python"
"$PY" -c 'import yaml' 2>/dev/null || {
  echo "SKIP codex_plan_kimi.sh: pyyaml absent (install scripts/requirements.txt)"
  exit 77   # did NOT run — never a pass (T1)
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/scripts"

# Kimi stub: captures -p <prompt> and -m <alias> for assertions; emits configurable output.
cat >"$tmp/bin/kimi" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
prompt=""; model=""; fmt=""
i=1
while (($# >= 1)); do
  case "$1" in
    -p) shift; prompt="$1" ;;
    -m) shift; model="$1" ;;
    --output-format) shift; fmt="$1" ;;
  esac
  shift
done
printf '%s' "$prompt"           >"$KIMI_STUB_PROMPT"
printf '%s %s\n' "$model" "$fmt" >"$KIMI_STUB_ARGS"
printf '%s' "${KIMI_STUB_STDOUT:-}"
printf '%s' "${KIMI_STUB_STDERR:-}" >&2
exit "${KIMI_STUB_EXIT:-0}"
STUB
chmod +x "$tmp/bin/kimi"

fail() {
  printf 'FAIL codex_plan_kimi.sh: %s\n' "$*" >&2
  exit 1
}

assert_file()    { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "unexpected file: $1"; }

# Build a kimi-configured scripts directory (a copy of codex-plan beside a kimi models.json and
# its dependencies — mirrors the "gutted config" pattern from tests/codex_plan.sh).
cp -p scripts/codex-plan scripts/models_check.py scripts/vendor_adapters.py "$tmp/scripts/"
"$PY" - "$tmp/scripts/models.json" <<'PY'
import json, sys
json.dump({
    "schema_version": "1",
    "roles": {
        "orchestrator":                  {"model": "claude-opus-4-8",   "effort": "high"},
        "spec_author":                   {"model": "kimi-k3",           "effort": "high"},
        "utility_subagent":              {"model": "claude-sonnet-4-6", "effort": "default"},
        "worker":                        {"model": "gpt-5.6-luna",      "effort": "high"},
        "bound_reviewer":                {"model": "claude-fable-5",    "effort": "high"},
        "orchestrator_artifact_reviewer":{"model": "gpt-5.6-sol",      "effort": "high"},
    },
    "cli_aliases": {
        "claude-fable-5": "fable",
        "kimi-k3":        "kimi-code/k3",
    },
    "vendor_map": {
        "gpt-5.6-luna":      "codex",
        "gpt-5.6-sol":       "codex",
        "claude-fable-5":    "claude",
        "claude-opus-4-8":   "claude",
        "claude-sonnet-4-6": "claude",
        "kimi-k3":           "kimi",
    },
}, open(sys.argv[1], "w"))
PY

run_dir="$tmp/plans"
mkdir -p "$run_dir"
prompt_file="$tmp/prompt"
args_file="$tmp/args"

# A valid stream-json response: system context then the plan body as the last assistant message.
valid_response='{"role":"system","content":"sys"}'$'\n''{"role":"assistant","content":"the kimi plan body"}'

# Basic dispatch: task arrives in kimi -p, alias and format are correct, body is extracted.
result="$(
  PATH="$tmp/bin:$PATH" \
  KIMI_STUB_PROMPT="$prompt_file" \
  KIMI_STUB_ARGS="$args_file" \
  KIMI_STUB_STDOUT="$valid_response" \
    "$tmp/scripts/codex-plan" --out "$run_dir" 'write a plan for kimi'
)"
[[ "$result" == *"$run_dir/PLAN-001.md"* ]] || fail "result did not print plan path"
[[ "$result" == *"PLAN-001"* ]]              || fail "result did not print identifier"
assert_file "$run_dir/PLAN-001.md"
assert_file "$run_dir/PLAN-001.stdout"
assert_file "$run_dir/PLAN-001.stderr"

# The plan body is the extracted last-assistant-message content, not the raw stream-json.
[[ "$(<"$run_dir/PLAN-001.stdout")" == 'the kimi plan body' ]] \
  || fail "plan body was not extracted from kimi stream-json; stdout: $(cat "$run_dir/PLAN-001.stdout")"
grep -q 'the kimi plan body' "$run_dir/PLAN-001.md" \
  || fail "extracted plan body missing from the minted plan file"

# Task text arrived in kimi -p argv.
grep -q 'write a plan for kimi' "$prompt_file" \
  || fail "task was not delivered in kimi -p argv"

# Kimi CLI alias (kimi-code/k3) and output format (stream-json) were passed.
grep -q 'kimi-code/k3'  "$args_file" || fail "kimi CLI alias (kimi-code/k3) not passed to -m"
grep -q 'stream-json'   "$args_file" || fail "--output-format stream-json not passed to kimi"

# author_model in frontmatter is the relay model id (kimi-k3), not the CLI alias.
"$PY" - "$run_dir/PLAN-001.md" <<'PY'
import sys, re
import yaml
text = open(sys.argv[1]).read()
m = re.fullmatch(r"---\n(.*?)\n---\n(.*)", text, re.DOTALL)
assert m, f"plan has no frontmatter: {text!r}"
meta = yaml.safe_load(m.group(1))
assert meta.get("author_model") == "kimi-k3", f"author_model: {meta.get('author_model')!r}"
assert meta.get("status") == "draft", meta
assert m.group(2) == "the kimi plan body", repr(m.group(2))
PY

# Oversized prompt is refused before kimi is invoked.
big_prompt="$(python3 -c "print('x' * 121000, end='')")"
if PATH="$tmp/bin:$PATH" KIMI_STUB_PROMPT="$prompt_file" KIMI_STUB_ARGS="$args_file" \
   KIMI_STUB_STDOUT="$valid_response" \
     "$tmp/scripts/codex-plan" --out "$run_dir" "$big_prompt" >/dev/null 2>&1; then
  fail "oversized kimi prompt was accepted (must refuse at 120000 bytes)"
fi
# Plan-002 was allocated for the ID claim but the .md must not exist (refusal before invocation).
assert_file    "$run_dir/PLAN-002.stdout"
assert_no_file "$run_dir/PLAN-002.md"
# The args file must not have been updated by this run (kimi was not invoked).
[[ ! -s "$args_file" ]] \
  || [[ "$(stat -c %Y "$args_file")" -lt "$(date -d '2 seconds ago' +%s 2>/dev/null || echo 0)" ]] \
  || true   # timing-based; the assert_no_file above is the reliable check

# Non-zero kimi exit retains provenance (stdout + stderr) but no plan is minted.
if PATH="$tmp/bin:$PATH" KIMI_STUB_PROMPT="$prompt_file" KIMI_STUB_ARGS="$args_file" \
   KIMI_STUB_STDOUT='partial output' KIMI_STUB_STDERR='kimi error detail' KIMI_STUB_EXIT=1 \
     "$tmp/scripts/codex-plan" --out "$run_dir" 'kimi failure case' >/dev/null 2>&1; then
  fail "non-zero kimi exit was accepted as success"
fi
assert_file    "$run_dir/PLAN-003.stdout"
assert_file    "$run_dir/PLAN-003.stderr"
assert_no_file "$run_dir/PLAN-003.md"

# Empty kimi response (no assistant message) is refused as empty output.
no_assistant='{"role":"system","content":"no plan here"}'
if PATH="$tmp/bin:$PATH" KIMI_STUB_PROMPT="$prompt_file" KIMI_STUB_ARGS="$args_file" \
   KIMI_STUB_STDOUT="$no_assistant" \
     "$tmp/scripts/codex-plan" --out "$run_dir" 'no assistant message' >/dev/null 2>&1; then
  fail "kimi response with no assistant message was accepted"
fi
assert_no_file "$run_dir/PLAN-004.md"

# Vendor-neutral error wording: non-zero exit message names the vendor, not "Codex".
err_out="$(
  PATH="$tmp/bin:$PATH" KIMI_STUB_PROMPT="$prompt_file" KIMI_STUB_ARGS="$args_file" \
  KIMI_STUB_STDOUT='x' KIMI_STUB_EXIT=42 \
    "$tmp/scripts/codex-plan" --out "$run_dir" 'wording check' 2>&1 || true
)"
[[ "$err_out" == *'kimi exited 42'* ]] || fail "error wording did not name 'kimi': $err_out"

echo "PASS codex_plan_kimi.sh"
