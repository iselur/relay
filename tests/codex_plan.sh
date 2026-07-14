#!/usr/bin/env bash
# Standalone acceptance test for scripts/codex-plan. Codex is always a local stub.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# Two assertions below need pyyaml. CI installs it into .venv, not the system python — use the
# venv when present (absolute path: this test cd's around) so the assertions actually run there.
PY="python3"
[ -x "$ROOT/.venv/bin/python" ] && PY="$ROOT/.venv/bin/python"
"$PY" -c 'import yaml' 2>/dev/null || {
  echo "SKIP codex_plan.sh: pyyaml absent (install scripts/requirements.txt)"
  exit 77   # did NOT run — never a pass (T1)
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

args=("$@")
((${#args[@]} >= 1)) || exit 90
last=$((${#args[@]} - 1))
printf '%s\n' "${args[@]:0:last}" >"$CODEX_STUB_ARGS"
printf '%s' "${args[$last]}" >"$CODEX_STUB_PROMPT"

# The wrapper must detach Codex from its own task-input stream.
if IFS= read -r unexpected; then
  printf 'unexpected stdin: %s\n' "$unexpected" >&2
  exit 91
fi

printf '%s' "${CODEX_STUB_STDOUT:-stub plan output}"
printf '%s' "${CODEX_STUB_STDERR:-}" >&2
exit "${CODEX_STUB_EXIT:-0}"
STUB
chmod +x "$tmp/bin/codex"

fail() {
  printf 'FAIL codex_plan.sh: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_no_file() {
  [[ ! -e "$1" ]] || fail "unexpected file: $1"
}

run_dir="$tmp/plans"
mkdir -p "$run_dir"
printf '%s\n' 'older plan' >"$run_dir/PLAN-007.md"
printf 'first context marker\n\n' >"$tmp/context one.txt"
printf '%s\n' 'second context marker' >"$tmp/context-two.txt"

long_task="$(python3 - <<'PY'
print("Plan a release: it's important\nwith a second line and " + "x" * 220, end="")
PY
)"

args_file="$tmp/args"
prompt_file="$tmp/prompt"
result="$({
  PATH="$tmp/bin:$PATH" \
  CODEX_STUB_ARGS="$args_file" \
  CODEX_STUB_PROMPT="$prompt_file" \
  CODEX_STUB_STDOUT='complete default plan' \
    scripts/codex-plan --out "$run_dir" "$long_task"
})"

[[ "$result" == *"$run_dir/PLAN-008.md"* ]] || fail "result did not print plan path"
[[ "$result" == *"PLAN-008"* ]] || fail "result did not print identifier"
assert_file "$run_dir/PLAN-008.md"
assert_file "$run_dir/PLAN-008.stdout"
assert_file "$run_dir/PLAN-008.stderr"
[[ "$(<"$run_dir/PLAN-008.stdout")" == 'complete default plan' ]] || fail "raw stdout changed"

cat >"$tmp/expected-args" <<'EOF'
exec
-m
gpt-5.6-sol
-c
model_reasoning_effort=high
-c
service_tier=priority
--sandbox
read-only
--skip-git-repo-check
EOF
cmp -s "$tmp/expected-args" "$args_file" || fail "Codex execution settings differ"

for phrase in \
  'decision-complete' \
  'decision and' \
  'non-goals' \
  'assumptions' \
  'evidence' \
  'alternatives' \
  'boundaries' \
  'failure modes' \
  'ordered implementation' \
  'validation criteria' \
  'rollback'; do
  grep -qi "$phrase" "$prompt_file" || fail "default prompt missing: $phrase"
done

TASK="$long_task" PLAN="$run_dir/PLAN-008.md" "$PY" - <<'PY'
import datetime
import os
import re
from pathlib import Path

import yaml

text = Path(os.environ["PLAN"]).read_text()
match = re.fullmatch(r"---\n(.*?)\n---\n(.*)", text, re.DOTALL)
assert match, text
metadata = yaml.safe_load(match.group(1))
assert metadata == {
    "id": "PLAN-008",
    "created": metadata["created"],
    "author_model": "gpt-5.6-sol",
    "status": "draft",
    "task": os.environ["TASK"][:200],
}, metadata
created = metadata["created"]
assert isinstance(created, datetime.datetime), created
assert created.utcoffset() == datetime.timedelta(0), created
assert match.group(2) == "complete default plan", repr(match.group(2))
PY

# A repeatable --context preserves option order, and --small switches prompts.
small_result="$({
  PATH="$tmp/bin:$PATH" \
  CODEX_STUB_ARGS="$args_file" \
  CODEX_STUB_PROMPT="$prompt_file" \
  CODEX_STUB_STDOUT='micro plan body' \
    scripts/codex-plan --small \
      --context "$tmp/context one.txt" \
      --context "$tmp/context-two.txt" \
      --out "$run_dir" \
      'Make a tiny change'
})"
[[ "$small_result" == *"PLAN-009"* ]] || fail "identifier did not increment"
assert_file "$run_dir/PLAN-009.md"
grep -qi 'five-field micro-plan' "$prompt_file" || fail "small prompt not selected"
for field in objective scope action verification rollback; do
  grep -qi "$field" "$prompt_file" || fail "small prompt missing field: $field"
done
if grep -qi 'alternatives considered' "$prompt_file"; then
  fail "small prompt retained the default planning template"
fi
python3 - "$prompt_file" "$tmp/context one.txt" "$tmp/context-two.txt" <<'PY'
from pathlib import Path
import sys

prompt = Path(sys.argv[1]).read_text()
first_path = Path(sys.argv[2])
second_path = Path(sys.argv[3])
expected_suffix = (
    f"\n\nContext file: {first_path}\n---\n" + first_path.read_text()
    + f"\n\nContext file: {second_path}\n---\n" + second_path.read_text()
)
assert prompt.endswith(expected_suffix), repr(prompt)
PY

# With no positional task, input comes from stdin; --out has the documented default.
default_cwd="$tmp/default-cwd"
mkdir -p "$default_cwd"
pushd "$default_cwd" >/dev/null
stdin_result="$(
  printf '%s\n' 'task supplied on stdin' | \
    PATH="$tmp/bin:$PATH" \
    CODEX_STUB_ARGS="$args_file" \
    CODEX_STUB_PROMPT="$prompt_file" \
    CODEX_STUB_STDOUT='stdin task plan' \
      "$ROOT/scripts/codex-plan"
)"
popd >/dev/null
[[ "$stdin_result" == *'.orchestrator/plans/PLAN-001.md'* ]] || fail "default output path missing"
assert_file "$default_cwd/.orchestrator/plans/PLAN-001.md"
grep -q 'task supplied on stdin' "$prompt_file" || fail "stdin task missing from prompt"
PLAN="$default_cwd/.orchestrator/plans/PLAN-001.md" "$PY" - <<'PY'
import os
from pathlib import Path

import yaml

frontmatter = Path(os.environ["PLAN"]).read_text().split("---\n", 2)[1]
assert yaml.safe_load(frontmatter)["task"] == "task supplied on stdin\n"
PY

# Non-zero and empty results retain separate provenance but never create a plan.
if PATH="$tmp/bin:$PATH" \
  CODEX_STUB_ARGS="$args_file" \
  CODEX_STUB_PROMPT="$prompt_file" \
  CODEX_STUB_STDOUT='partial output' \
  CODEX_STUB_STDERR='failure detail' \
  CODEX_STUB_EXIT=23 \
    scripts/codex-plan --out "$run_dir" 'expected failure' >/dev/null 2>&1; then
  fail "non-zero Codex result was accepted"
fi
assert_no_file "$run_dir/PLAN-010.md"
assert_file "$run_dir/PLAN-010.stdout"
assert_file "$run_dir/PLAN-010.stderr"
[[ "$(<"$run_dir/PLAN-010.stdout")" == 'partial output' ]] || fail "failure stdout not retained"
[[ "$(<"$run_dir/PLAN-010.stderr")" == 'failure detail' ]] || fail "failure stderr not retained"

if PATH="$tmp/bin:$PATH" \
  CODEX_STUB_ARGS="$args_file" \
  CODEX_STUB_PROMPT="$prompt_file" \
  CODEX_STUB_STDOUT='   ' \
    scripts/codex-plan --out "$run_dir" 'empty output failure' >/dev/null 2>&1; then
  fail "whitespace-only Codex result was accepted"
fi
assert_no_file "$run_dir/PLAN-011.md"
assert_file "$run_dir/PLAN-011.stdout"
assert_file "$run_dir/PLAN-011.stderr"

echo "PASS codex_plan.sh"
