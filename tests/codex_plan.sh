#!/usr/bin/env bash
# Standalone acceptance test for scripts/codex-plan. Codex is always a local stub.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# Two assertions below need pyyaml. CI installs it into .venv, not the system python — use the
# venv when present (absolute path: this test cd's around) so the assertions actually run there.
PY="${ORCH_TEST_PY:-python3}"
[ -n "${ORCH_TEST_PY:-}" ] || [ ! -x "$ROOT/.venv/bin/python" ] || PY="$ROOT/.venv/bin/python"
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

# The prompt goes on STDIN and the final argument is the '-' that tells Codex to read it there.
# It used to be passed in argv, which dies over 130KB (AGENTS.md) — a brief-sized prompt with
# context files hit that limit and surfaced as an opaque Codex startup error.
[[ "${args[$last]}" == "-" ]] || { printf 'prompt not on stdin: last arg is %s\n' "${args[$last]}" >&2; exit 91; }
cat >"$CODEX_STUB_PROMPT"

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

# Each tier has its own cap (CLAUDE.md rule 5): --small 40, default 250, --brief 400. A body over
# its cap is refused, the raw output is retained, and no plan is minted. Exact boundaries, and the
# fixtures have NO terminal newline (the stub prints with printf '%s') — the cap must count a final
# unterminated line, which wc -l would miss. Both spellings of "N lines" must agree, so every
# boundary is checked with and without a terminal newline.
body() { python3 -c "print('\n'.join(f'line {i}' for i in range($1)), end='')"; }

check_cap() { # $1 tier flag ("" for default), $2 cap, $3 expected plan id at cap
  local flag=$1 cap=$2 at_id=$3
  local over under
  over="$(body $((cap + 1)))"
  under="$(body "$cap")"
  for suffix in '' $'\n'; do
    if PATH="$tmp/bin:$PATH" CODEX_STUB_ARGS="$args_file" CODEX_STUB_PROMPT="$prompt_file" \
      CODEX_STUB_STDOUT="$over$suffix" \
        scripts/codex-plan ${flag:+$flag} --out "$run_dir" 'oversized' >/dev/null 2>&1; then
      fail "a $((cap + 1))-line ${flag:-default} body was accepted (cap is $cap)"
    fi
    PATH="$tmp/bin:$PATH" CODEX_STUB_ARGS="$args_file" CODEX_STUB_PROMPT="$prompt_file" \
      CODEX_STUB_STDOUT="$under$suffix" \
        scripts/codex-plan ${flag:+$flag} --out "$run_dir" 'at the cap' >/dev/null \
      || fail "a $cap-line ${flag:-default} body (exactly at the cap) was refused"
  done
  assert_file "$run_dir/$at_id.md"
}

check_cap ''       250 PLAN-013
check_cap --small   40 PLAN-017
assert_file "$run_dir/PLAN-012.stdout"   # the refused oversized default retained its provenance

# --- the brief tier -----------------------------------------------------------------------------
# A brief must carry every required section, as REAL heading lines, in order, each with content
# under it. Every fixture below is a way the first (substring-scan) version of this check was
# fooled. Each valid brief fixture is padded to an exact line count so the 400/401 boundary is
# tested for real — the earlier version tested 399 and called it 400.
sections=(Outcome "Scope and non-goals" "Frozen decisions" Assumptions "Earliest falsifiable proof" \
          Gates Verification Rollback Deferred "Definition of done")
valid_brief() { # $1 = total line count (>= 20: ten headings + one content line each)
  local n=$1 filler=$(( $1 - 20 )) out=""
  for s in "${sections[@]}"; do out+="## $s"$'\n'"content for $s"$'\n'; done
  ((filler > 0)) && out+="$(body "$filler")"$'\n'
  printf '%s' "${out%$'\n'}"
}
try_brief() { # $1 = body; echoes ok/refused
  if PATH="$tmp/bin:$PATH" CODEX_STUB_ARGS="$args_file" CODEX_STUB_PROMPT="$prompt_file" \
    CODEX_STUB_STDOUT="$1" scripts/codex-plan --brief --out "$run_dir" 'brief' >/dev/null 2>&1
  then echo ok; else echo refused; fi
}

for suffix in '' $'\n'; do
  [ "$(try_brief "$(valid_brief 400)$suffix")" = ok ]      || fail "a 400-line brief (exactly at the cap) was refused"
  [ "$(try_brief "$(valid_brief 401)$suffix")" = refused ] || fail "a 401-line brief was accepted (cap is 400)"
done

# Structure, not substrings: each of these contains all ten heading strings and must still fail.
all_on_one_line=""; for s in "${sections[@]}"; do all_on_one_line+="## $s "; done
[ "$(try_brief "$all_on_one_line")" = refused ] || fail "ten headings crammed on ONE line were accepted as a brief"

fenced=$'```\n'"$(valid_brief 30)"$'\n```\nprose'
[ "$(try_brief "$fenced")" = refused ] || fail "headings inside a code fence were accepted as real sections"

empty_section=""; for s in "${sections[@]}"; do
  empty_section+="## $s"$'\n'; [ "$s" = Gates ] || empty_section+="content"$'\n'
done
[ "$(try_brief "$empty_section")" = refused ] || fail "a brief with an EMPTY '## Gates' section was accepted"

out_of_order=""; for s in "Scope and non-goals" Outcome "Frozen decisions" Assumptions \
    "Earliest falsifiable proof" Gates Verification Rollback Deferred "Definition of done"; do
  out_of_order+="## $s"$'\n'"content"$'\n'
done
[ "$(try_brief "$out_of_order")" = refused ] || fail "out-of-order sections were accepted"

near_miss="$(valid_brief 30)"; near_miss="${near_miss/'## Outcome'/'## Outcomes'}"
[ "$(try_brief "$near_miss")" = refused ] || fail "'## Outcomes' was accepted as '## Outcome'"

missing="$(valid_brief 30)"; missing="${missing/'## Earliest falsifiable proof'/'## Notes'}"
[ "$(try_brief "$missing")" = refused ] || fail "a brief with no 'Earliest falsifiable proof' section was accepted"

# A required heading twice = two answers to the same question, and nothing says which one binds.
duplicated="$(valid_brief 30)"$'\n## Outcome\na second, contradictory outcome'
[ "$(try_brief "$duplicated")" = refused ] || fail "a brief with TWO '## Outcome' sections was accepted"

# The brief prompt must actually ask for the anatomy — the cap alone does not make a brief a brief.
grep -qi 'earliest falsifiable' "$prompt_file" || fail "brief prompt missing the falsifiable-proof section"

# Contradictory tiers are refused, never last-flag-wins: "ambiguity picks the higher tier".
for combo in "--small --brief" "--brief --small"; do
  if PATH="$tmp/bin:$PATH" CODEX_STUB_ARGS="$args_file" CODEX_STUB_PROMPT="$prompt_file" \
    CODEX_STUB_STDOUT='x' scripts/codex-plan $combo --out "$run_dir" 'contradictory tiers' >/dev/null 2>&1; then
    fail "'$combo' was accepted; contradictory tier flags must be refused"
  fi
done

# --- the regression the stdin fix exists for ----------------------------------------------------
# The prompt used to travel in argv, which dies over ~130KB (AGENTS.md) — precisely what a brief
# with real context files produces. Feed a 200KB context and require the WHOLE prompt to arrive on
# the stub's stdin: an argv-passing wrapper cannot survive this.
big_context="$tmp/big-context.txt"
python3 -c "open('$big_context','w').write('CONTEXT-HEAD\n' + 'padding line to make this large\n' * 6000 + 'CONTEXT-TAIL\n')"
[ "$(wc -c <"$big_context")" -gt 130000 ] || fail "large-context fixture is not actually over 130KB"
PATH="$tmp/bin:$PATH" CODEX_STUB_ARGS="$args_file" CODEX_STUB_PROMPT="$prompt_file" \
  CODEX_STUB_STDOUT='plan from a large prompt' \
    scripts/codex-plan --context "$big_context" --out "$run_dir" 'large context task' >/dev/null \
  || fail "a prompt with a 200KB context file failed (the argv limit regression is back)"
grep -q 'CONTEXT-HEAD' "$prompt_file" || fail "large prompt: the head of the context never reached Codex"
grep -q 'CONTEXT-TAIL' "$prompt_file" || fail "large prompt: the TAIL of the context was truncated"
[ "$(wc -c <"$prompt_file")" -gt 130000 ] || fail "large prompt arrived truncated below the argv limit"

# B17: allocation must honor the directory lock. Two checks; the FIRST is the deterministic
# regression discriminator (round-2): while this test holds the lock, a run must be unable to
# allocate ANYTHING — the unfixed script ignores the advisory lock and completes in milliseconds,
# so "still blocked after 2s with zero artifacts" separates the implementations without racing
# two scans against each other.
conc_dir="$tmp/plans-conc"
mkdir -p "$conc_dir"
exec 7>>"$conc_dir/.plan-id.lock"
flock 7
PATH="$tmp/bin:$PATH" CODEX_STUB_ARGS="$tmp/probe-args" CODEX_STUB_PROMPT="$tmp/probe-prompt" \
  CODEX_STUB_STDOUT='lock probe plan' \
  scripts/codex-plan --small --out "$conc_dir" 'lock honor probe' >"$tmp/probe.out" 2>&1 &
probe_pid=$!
sleep 2   # ~1000x the stubbed run's wall clock; the unfixed script has long finished by now
kill -0 "$probe_pid" 2>/dev/null \
  || fail "codex-plan completed while the allocation lock was held (lock not honored — B17 regressed): $(cat "$tmp/probe.out")"
! compgen -G "$conc_dir/PLAN-*" >/dev/null \
  || fail "artifacts allocated while the allocation lock was held: $(ls "$conc_dir")"
flock -u 7
wait "$probe_pid" || fail "probe run failed after lock release: $(cat "$tmp/probe.out")"
assert_file "$conc_dir/PLAN-001.md"

# Second check: two concurrent runs allocate DISTINCT ids with both bodies intact. The claim
# (noclobber create of .stdout under the lock) serializes the scans.
exec 7>>"$conc_dir/.plan-id.lock"
flock 7
PATH="$tmp/bin:$PATH" CODEX_STUB_ARGS="$tmp/conc-args-1" CODEX_STUB_PROMPT="$tmp/conc-prompt-1" \
  CODEX_STUB_STDOUT='concurrent plan ONE' \
  scripts/codex-plan --small --out "$conc_dir" 'concurrent task one' >"$tmp/conc1.out" 2>&1 &
conc_pid1=$!
PATH="$tmp/bin:$PATH" CODEX_STUB_ARGS="$tmp/conc-args-2" CODEX_STUB_PROMPT="$tmp/conc-prompt-2" \
  CODEX_STUB_STDOUT='concurrent plan TWO' \
  scripts/codex-plan --small --out "$conc_dir" 'concurrent task two' >"$tmp/conc2.out" 2>&1 &
conc_pid2=$!
sleep 1   # let both queue on the held lock before releasing it
flock -u 7
wait "$conc_pid1" || fail "concurrent run 1 failed: $(cat "$tmp/conc1.out")"
wait "$conc_pid2" || fail "concurrent run 2 failed: $(cat "$tmp/conc2.out")"
conc_plans=("$conc_dir"/PLAN-*.md)
[ "${#conc_plans[@]}" -eq 3 ] \
  || fail "expected 3 plans (probe + 2 distinct concurrent), got: ${conc_plans[*]-none}"
grep -q 'concurrent plan ONE' "$conc_dir"/PLAN-002.md "$conc_dir"/PLAN-003.md 2>/dev/null \
  || fail "concurrent plan ONE missing from the allocated ids"
grep -q 'concurrent plan TWO' "$conc_dir"/PLAN-002.md "$conc_dir"/PLAN-003.md 2>/dev/null \
  || fail "concurrent plan TWO missing from the allocated ids (an overwrite ate it)"

# R71 (round-1 review): the WHOLE models config is validated before drafting — a copy of the
# script beside a config missing a required section must refuse, even though its own
# roles.spec_author.model value is present and readable.
mkdir -p "$tmp/gutted/scripts"
cp -p scripts/codex-plan scripts/models_check.py "$tmp/gutted/scripts/"
"$PY" - scripts/models.json "$tmp/gutted/scripts/models.json" <<'GUT'
import json, sys
cfg = json.load(open(sys.argv[1])); del cfg["vendor_map"]
json.dump(cfg, open(sys.argv[2], "w"))
GUT
if PATH="$tmp/bin:$PATH" CODEX_STUB_ARGS="$tmp/gut-args" CODEX_STUB_PROMPT="$tmp/gut-prompt" \
    "$tmp/gutted/scripts/codex-plan" --small --out "$tmp/gutted-out" 'should refuse' \
    >"$tmp/gutted.out" 2>&1; then
  fail "codex-plan drafted with a config missing vendor_map: $(cat "$tmp/gutted.out")"
fi
grep -qi 'models config' "$tmp/gutted.out" \
  || fail "gutted-config refusal did not name the models config: $(cat "$tmp/gutted.out")"
[ ! -e "$tmp/gutted-out" ] || fail "gutted-config refusal still created an output dir"

echo "PASS codex_plan.sh"
