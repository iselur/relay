#!/usr/bin/env bash
# Byte/status oracle for invoke-answer. The base runner below is extracted from the committed
# codex-plan snapshot; it is deliberately not a shell reimplementation of either vendor arm.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE=tests/parity_base
for file in BASE_SHA vendor_adapters.py models_check.py models.json codex-plan review; do
  [[ -f "$BASE/$file" ]] || { echo "FAIL missing base fixture: $BASE/$file" >&2; exit 1; }
done
BASE_SHA=$(<"$BASE/BASE_SHA")
[[ "$(wc -c <"$BASE/BASE_SHA")" == 41 && "$BASE_SHA" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "FAIL malformed parity BASE_SHA" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# CI has the dispatch commit and verifies every fixture byte. Candidate-isolated grading has no
# reachable Git metadata and runs exclusively from the committed fixture after cat-file fails.
if command -v git >/dev/null && git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  for path in scripts/vendor_adapters.py scripts/models_check.py scripts/models.json scripts/codex-plan scripts/review; do
    git show "$BASE_SHA:$path" >"$tmp/git-show"
    cmp "$tmp/git-show" "$BASE/${path#scripts/}" \
      || { echo "FAIL base fixture differs from $BASE_SHA:$path" >&2; exit 1; }
  done
fi

mkdir -p "$tmp/base/scripts" "$tmp/cli/scripts" "$tmp/bin"
cp "$BASE"/{vendor_adapters.py,models_check.py,models.json,codex-plan} "$tmp/base/scripts/"
cp scripts/vendor_adapters.py "$tmp/cli/scripts/"
cp "$BASE"/{models_check.py,models.json} "$tmp/cli/scripts/"

# Slice 2 drives the complete committed review fixture, so its config gate, round locking, output
# paths, and exit translation remain part of the oracle. The base side contains base bytes only.
mkdir -p "$tmp/review-base/scripts" "$tmp/review-cli/scripts"
cp "$BASE"/{review,models_check.py,models.json} "$tmp/review-base/scripts/"
cp scripts/{review,vendor_adapters.py,models_check.py,models.json} "$tmp/review-cli/scripts/"
chmod +x "$tmp/review-base/scripts/review" "$tmp/review-cli/scripts/review"
# Copies inherit source modes; the integrate gate runs this test from a write-stripped grader
# tree, so restore user write or every later overwrite of a copied fixture dies with EACCES.
chmod -R u+w "$tmp"
printf 'plain claude review context\n' >"$tmp/review-context.txt"

# This is the point where committed base bytes become executable oracle behavior. Both the
# config-resolution block and vendor case are extracted verbatim. The sole mechanical transport
# edit removes codex-plan's printf pipe so the extracted Codex command reads the prompt file
# directly, allowing the oracle to exercise stdin bytes (including NUL) that Bash variables cannot
# hold. Missing/changed delimiters or transport text aborts generation loudly.
python3 - "$BASE/codex-plan" "$tmp/base/scripts/base-invoke" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
config_start = 'SCRIPTS_DIR="$(dirname "$(realpath "$0")")"\n'
config_end = '\n\nwhile (($#)); do'
invoke_start = 'vendor_status=0\ncase "$VENDOR" in\n'
invoke_end = '\nesac\n\nif ((vendor_status != 0)); then'
for marker in (config_start, config_end, invoke_start, invoke_end):
    if source.count(marker) != 1:
        raise SystemExit(f"base codex-plan delimiter absent or ambiguous: {marker!r}")
config = source[source.index(config_start):source.index(config_end)]
invoke = source[source.index(invoke_start):source.index(invoke_end) + len('\nesac')]
transport = "    if printf '%s' \"$prompt\" | codex exec \\\n"
if invoke.count(transport) != 1:
    raise SystemExit("base Codex stdin transport line absent or ambiguous")
invoke = invoke.replace(transport, "    if codex exec \\\n")
wrapper = '''#!/usr/bin/env bash
set -uo pipefail
die() { printf 'base-invoke: %s\\n' "$*" >&2; exit 2; }
prompt_path=$1
stdout_path=$2
stderr_path=$3
prompt="$(cat -- "$prompt_path"; printf '\\034')"
prompt="${prompt%$'\\034'}"
exec <"$prompt_path"
'''
Path(sys.argv[2]).write_text(wrapper + config + "\n\n" + invoke + '\nexit "$vendor_status"\n')
Path(sys.argv[2]).chmod(0o755)
PY

# The stubs record the complete argv vector before inspecting any option, then record the prompt.
# They also prove fd 3 was closed before exec. STUB_OUTPUT supplies exact vendor stdout bytes.
cat >"$tmp/bin/vendor-stub" <<'SH'
#!/usr/bin/env bash
set -u
if { : >&3; } 2>/dev/null; then
  printf inherited >"$STUB_INHERITED"
fi
: >"$STUB_ARGV"
for arg in "$@"; do printf '%s\0' "$arg" >>"$STUB_ARGV"; done
args=("$@")
case "${0##*/}" in
  codex)
    cat >"$STUB_PROMPT"
    ;;
  kimi)
    : >"$STUB_PROMPT"
    for ((i=0; i<${#args[@]}; i++)); do
      if [[ "${args[i]}" == -p && $((i + 1)) -lt ${#args[@]} ]]; then
        printf '%s' "${args[i + 1]}" >"$STUB_PROMPT"
        break
      fi
    done
    ;;
esac
[[ -n "${STUB_STDERR:-}" ]] && printf '%s' "$STUB_STDERR" >&2
case "${STUB_MODE:-output}" in
  output) cat "$STUB_OUTPUT" ;;
  exit) exit "$STUB_EXIT" ;;
  signal) kill -TERM $$; sleep 1 ;;
esac
SH
chmod +x "$tmp/bin/vendor-stub"
ln -s vendor-stub "$tmp/bin/codex"
ln -s vendor-stub "$tmp/bin/kimi"

failures=0
ok() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
assert_status() {
  local name=$1 got=$2 want=$3
  [[ "$got" == "$want" ]] && ok "$name status $want" || fail "$name status: got $got, want $want"
}
assert_cmp() {
  local name=$1 left=$2 right=$3
  cmp "$left" "$right" >/dev/null && ok "$name bytes" || fail "$name bytes differ"
}

configure() {
  local vendor=$1 role=$2
  python3 - "$BASE/models.json" "$tmp/base/scripts/models.json" \
    "$tmp/cli/scripts/models.json" "$vendor" "$role" <<'PY'
import json, sys
cfg = json.loads(open(sys.argv[1]).read())
if sys.argv[4] == "kimi":
    cfg["roles"][sys.argv[5]] = {"model": "kimi-k3", "effort": "max"}
data = json.dumps(cfg, indent=2) + "\n"
for path in sys.argv[2:4]:
    open(path, "w").write(data)
PY
  cmp "$tmp/base/scripts/models.json" "$tmp/cli/scripts/models.json"
}

run_status() {
  set +e
  "$@"
  RUN_STATUS=$?
  set -e
}

run_pair() {
  local name=$1 vendor=$2 role=$3 prompt=$4 output=$5 base_want=$6 cli_want=$7
  configure "$vendor" "$role"
  rm -f "$tmp"/{base.argv,cli.argv,base.prompt,cli.prompt,base.inherited,cli.inherited,base.out,cli.out,base.err,cli.err,cli.raw}
  export PATH="$tmp/bin:$PATH" STUB_MODE=output STUB_OUTPUT="$output" STUB_STDERR=""
  export STUB_ARGV="$tmp/base.argv" STUB_PROMPT="$tmp/base.prompt" \
         STUB_INHERITED="$tmp/base.inherited"
  run_status "$tmp/base/scripts/base-invoke" "$prompt" "$tmp/base.out" "$tmp/base.err"
  local base_status=$RUN_STATUS
  export STUB_ARGV="$tmp/cli.argv" STUB_PROMPT="$tmp/cli.prompt" \
         STUB_INHERITED="$tmp/cli.inherited"
  run_status python3 "$tmp/cli/scripts/vendor_adapters.py" invoke-answer --role "$role" \
    --raw "$tmp/cli.raw" <"$prompt" >"$tmp/cli.out" 2>"$tmp/cli.err"
  local cli_status=$RUN_STATUS
  assert_status "$name base" "$base_status" "$base_want"
  assert_status "$name CLI" "$cli_status" "$cli_want"
  if [[ -e "$tmp/base.argv" || -e "$tmp/cli.argv" ]]; then
    [[ -e "$tmp/base.argv" && -e "$tmp/cli.argv" ]] \
      && assert_cmp "$name complete argv" "$tmp/base.argv" "$tmp/cli.argv" \
      || fail "$name launched only one vendor side"
    [[ -e "$tmp/base.prompt" && -e "$tmp/cli.prompt" ]] \
      && assert_cmp "$name vendor prompt" "$tmp/base.prompt" "$tmp/cli.prompt" \
      || fail "$name missing recorded prompt"
  fi
  if [[ "$base_status" == 0 && "$cli_status" == 0 ]]; then
    assert_cmp "$name recovered answer" "$tmp/base.out" "$tmp/cli.out"
  fi
  [[ ! -e "$tmp/base.inherited" && ! -e "$tmp/cli.inherited" ]] \
    && ok "$name vendor did not inherit fd 3" || fail "$name vendor inherited fd 3"
  [[ ! -e "$tmp/cli.raw" || -e "$output" ]] || fail "$name raw capture unexpected"
}

printf 'prompt without newline' >"$tmp/prompt"
printf 'codex answer\nsecond line' >"$tmp/codex-output"
printf '{"role":"assistant","content":"kimi answer\\nsecond line"}\n' >"$tmp/kimi-output"
run_pair 'Codex nonempty success' codex spec_author "$tmp/prompt" "$tmp/codex-output" 0 0
assert_cmp 'Codex raw stdout retained' "$tmp/codex-output" "$tmp/cli.raw"
run_pair 'Kimi nonempty success' kimi spec_author "$tmp/prompt" "$tmp/kimi-output" 0 0
assert_cmp 'Kimi raw stdout retained' "$tmp/kimi-output" "$tmp/cli.raw"

: >"$tmp/empty"
run_pair 'Codex empty success' codex spec_author "$tmp/prompt" "$tmp/empty" 0 0
run_pair 'Kimi empty success' kimi spec_author "$tmp/prompt" "$tmp/empty" 0 0

# Whole-config validation happens before either side can launch a subprocess.
configure codex spec_author
python3 - "$tmp/base/scripts/models.json" "$tmp/cli/scripts/models.json" <<'PY'
import json, sys
cfg = json.loads(open(sys.argv[1]).read()); cfg["unexpected"] = True
data = json.dumps(cfg) + "\n"
for path in sys.argv[1:]: open(path, "w").write(data)
PY
rm -f "$tmp"/{base.argv,cli.argv,base.prompt,cli.prompt}
export STUB_ARGV="$tmp/base.argv" STUB_PROMPT="$tmp/base.prompt" STUB_INHERITED="$tmp/base.inherited"
run_status "$tmp/base/scripts/base-invoke" "$tmp/prompt" "$tmp/base.out" "$tmp/base.err"
assert_status 'whole-config failure base' "$RUN_STATUS" 2
export STUB_ARGV="$tmp/cli.argv" STUB_PROMPT="$tmp/cli.prompt" STUB_INHERITED="$tmp/cli.inherited"
rm -f "$tmp/config.fd3"
run_status python3 "$tmp/cli/scripts/vendor_adapters.py" invoke-answer --role spec_author \
  <"$tmp/prompt" >"$tmp/cli.out" 2>"$tmp/cli.err" 3>"$tmp/config.fd3"
assert_status 'whole-config failure CLI' "$RUN_STATUS" 99
[[ ! -e "$tmp/base.argv" && ! -e "$tmp/cli.argv" ]] \
  && ok 'whole-config failure launched no vendor' || fail 'whole-config failure launched vendor'
[[ ! -s "$tmp/config.fd3" ]] \
  && ok 'whole-config failure emitted no model record' || fail 'model emitted before config validation'

# The UTF-8 byte wall is inclusive at 120000 and refuses 120001 before exec.
python3 - "$tmp/limit" "$tmp/over" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes("é".encode() * 60000)
Path(sys.argv[2]).write_bytes("é".encode() * 60000 + b"x")
PY
run_pair 'Kimi multibyte 120000 boundary' kimi spec_author "$tmp/limit" "$tmp/kimi-output" 0 0
run_pair 'Kimi multibyte 120001 refusal' kimi spec_author "$tmp/over" "$tmp/kimi-output" 1 97
[[ ! -e "$tmp/base.argv" && ! -e "$tmp/cli.argv" ]] \
  && ok 'Kimi 120001 refused before vendor exec' || fail 'Kimi 120001 launched vendor'

# Worker recovery intentionally keeps the last valid assistant message despite trailing damage.
printf '{"role":"assistant","content":"kept"}\nnot-json\n' >"$tmp/kimi-malformed"
run_pair 'Kimi spec_author trailing damage' kimi spec_author "$tmp/prompt" "$tmp/kimi-malformed" 0 0

# Reviewer recovery is fail-closed. The base status is produced by the snapshot KimiReviewer,
# not a recreated parser; CLI 98 must retain the exact raw vendor stream at the caller path.
configure kimi orchestrator_artifact_reviewer
printf '{"role":"assistant","content":"{\\"verdict\\":\\"PASS\\"}"}\nnot-json\n' \
  >"$tmp/kimi-review-malformed"
run_status env PYTHONPATH="$tmp/base/scripts" python3 - "$tmp/kimi-review-malformed" <<'PY'
from pathlib import Path
from vendor_adapters import KimiReviewer
import sys
raw = Path(sys.argv[1]).read_text()
raise SystemExit(0 if KimiReviewer().extract_verdict(raw) is not None else 1)
PY
review_base_status=$RUN_STATUS
rm -f "$tmp/cli.argv" "$tmp/cli.prompt" "$tmp/cli.inherited"
printf caller-owned >"$tmp/cli.raw"
export STUB_ARGV="$tmp/cli.argv" STUB_PROMPT="$tmp/cli.prompt" STUB_INHERITED="$tmp/cli.inherited" \
       STUB_OUTPUT="$tmp/kimi-review-malformed"
run_status python3 "$tmp/cli/scripts/vendor_adapters.py" invoke-answer \
  --role orchestrator_artifact_reviewer --raw "$tmp/cli.raw" \
  <"$tmp/prompt" >"$tmp/cli.out" 2>"$tmp/cli.err"
assert_status 'Kimi reviewer recovery base' "$review_base_status" 1
assert_status 'Kimi reviewer recovery CLI' "$RUN_STATUS" 98
assert_cmp 'Kimi reviewer failure retains raw' "$tmp/kimi-review-malformed" "$tmp/cli.raw"

# An empty vendor stream is not a verdict either: reviewer-role empty output fails closed.
rm -f "$tmp/cli.argv" "$tmp/cli.prompt" "$tmp/cli.inherited"
export STUB_ARGV="$tmp/cli.argv" STUB_PROMPT="$tmp/cli.prompt" STUB_INHERITED="$tmp/cli.inherited" \
       STUB_OUTPUT="$tmp/empty"
run_status python3 "$tmp/cli/scripts/vendor_adapters.py" invoke-answer \
  --role orchestrator_artifact_reviewer \
  <"$tmp/prompt" >"$tmp/cli.out" 2>"$tmp/cli.err"
assert_status 'Kimi reviewer empty output fails closed' "$RUN_STATUS" 98

# A non-empty stream recovering to a blank assistant message is not a verdict either.
printf '{"role":"assistant","content":" \\n"}\n' >"$tmp/kimi-blank"
rm -f "$tmp/cli.argv" "$tmp/cli.prompt" "$tmp/cli.inherited"
export STUB_ARGV="$tmp/cli.argv" STUB_PROMPT="$tmp/cli.prompt" STUB_INHERITED="$tmp/cli.inherited" \
       STUB_OUTPUT="$tmp/kimi-blank"
run_status python3 "$tmp/cli/scripts/vendor_adapters.py" invoke-answer \
  --role orchestrator_artifact_reviewer \
  <"$tmp/prompt" >"$tmp/cli.out" 2>"$tmp/cli.err"
assert_status 'Kimi reviewer blank answer fails closed' "$RUN_STATUS" 98

# Ordinary and reserved vendor statuses apply to both supported vendors.
for vendor in codex kimi; do
  for code in 42 96 97 98 99; do
    configure "$vendor" spec_author
    rm -f "$tmp"/{base.argv,cli.argv,base.prompt,cli.prompt}
    export STUB_MODE=exit STUB_EXIT=$code STUB_OUTPUT="$tmp/empty"
    export STUB_ARGV="$tmp/base.argv" STUB_PROMPT="$tmp/base.prompt" STUB_INHERITED="$tmp/base.inherited"
    run_status "$tmp/base/scripts/base-invoke" "$tmp/prompt" "$tmp/base.out" "$tmp/base.err"
    base_status=$RUN_STATUS
    export STUB_ARGV="$tmp/cli.argv" STUB_PROMPT="$tmp/cli.prompt" STUB_INHERITED="$tmp/cli.inherited"
    run_status python3 "$tmp/cli/scripts/vendor_adapters.py" invoke-answer --role spec_author \
      <"$tmp/prompt" >"$tmp/cli.out" 2>"$tmp/cli.err"
    cli_status=$RUN_STATUS
    assert_status "$vendor vendor exit $code base" "$base_status" "$code"
    if ((code >= 96)); then
      assert_status "$vendor vendor exit $code CLI" "$cli_status" 96
      grep -F "reserved status $code" "$tmp/cli.err" >/dev/null \
        && ok "$vendor vendor exit $code named original status" \
        || fail "$vendor vendor exit $code did not name original status"
    else
      assert_status "$vendor vendor exit $code CLI" "$cli_status" "$code"
    fi
    assert_cmp "$vendor exit $code complete argv" "$tmp/base.argv" "$tmp/cli.argv"
    assert_cmp "$vendor exit $code prompt" "$tmp/base.prompt" "$tmp/cli.prompt"
  done
done

# A real signal termination must remain shell-observable 143, never Python's wrapped 241.
for vendor in codex kimi; do
  configure "$vendor" spec_author
  export STUB_MODE=signal STUB_OUTPUT="$tmp/empty"
  export STUB_ARGV="$tmp/base.argv" STUB_PROMPT="$tmp/base.prompt" STUB_INHERITED="$tmp/base.inherited"
  run_status "$tmp/base/scripts/base-invoke" "$tmp/prompt" "$tmp/base.out" "$tmp/base.err"
  assert_status "$vendor SIGTERM base" "$RUN_STATUS" 143
  export STUB_ARGV="$tmp/cli.argv" STUB_PROMPT="$tmp/cli.prompt" STUB_INHERITED="$tmp/cli.inherited"
  run_status python3 "$tmp/cli/scripts/vendor_adapters.py" invoke-answer --role spec_author \
    <"$tmp/prompt" >"$tmp/cli.out" 2>"$tmp/cli.err"
  assert_status "$vendor SIGTERM CLI" "$RUN_STATUS" 143
done

# NUL is valid Codex stdin and invalid Kimi argv. The Kimi refusal leaves a caller path untouched.
printf 'before\0after' >"$tmp/nul"
export STUB_MODE=output STUB_OUTPUT="$tmp/codex-output"
run_pair 'Codex NUL stdin' codex spec_author "$tmp/nul" "$tmp/codex-output" 0 0
assert_cmp 'Codex NUL prompt reaches base' "$tmp/nul" "$tmp/base.prompt"
assert_cmp 'Codex NUL prompt reaches CLI' "$tmp/nul" "$tmp/cli.prompt"
configure kimi spec_author
rm -f "$tmp/cli.argv" "$tmp/cli.prompt"
printf caller-owned >"$tmp/cli.raw"
export STUB_ARGV="$tmp/cli.argv" STUB_PROMPT="$tmp/cli.prompt" STUB_INHERITED="$tmp/cli.inherited"
run_status python3 "$tmp/cli/scripts/vendor_adapters.py" invoke-answer --role spec_author \
  --raw "$tmp/cli.raw" <"$tmp/nul" >"$tmp/cli.out" 2>"$tmp/cli.err"
assert_status 'Kimi NUL refusal CLI' "$RUN_STATUS" 97
[[ ! -e "$tmp/cli.argv" ]] && ok 'Kimi NUL refused before vendor exec' || fail 'Kimi NUL launched vendor'
printf caller-owned >"$tmp/caller-owned"
assert_cmp 'Kimi refusal preserves caller raw path' "$tmp/caller-owned" "$tmp/cli.raw"

# Codex stdin has no argv-size ceiling, and prompt terminal newlines are neither added nor removed.
python3 - "$tmp/large" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b"L" * 140000)
PY
run_pair 'Codex over 130KB stdin' codex spec_author "$tmp/large" "$tmp/codex-output" 0 0
printf 'ends with two newlines\n\n' >"$tmp/trailing"
run_pair 'Codex trailing-newline prompt' codex spec_author "$tmp/trailing" "$tmp/codex-output" 0 0
assert_cmp 'Codex trailing-newline exact prompt' "$tmp/trailing" "$tmp/cli.prompt"
run_pair 'Kimi trailing-newline prompt' kimi spec_author "$tmp/trailing" "$tmp/kimi-output" 0 0
assert_cmp 'Kimi trailing-newline exact prompt' "$tmp/trailing" "$tmp/cli.prompt"

# fd 3 is an authenticated side channel: exact bytes/value, immune to forged vendor output and
# stderr, absent from the child, and optional when the caller does not open it.
configure codex orchestrator_artifact_reviewer
printf 'model=forged-stdout\n' >"$tmp/forged-output"
printf 'model=gpt-5.6-luna\n' >"$tmp/expected-fd3"
rm -f "$tmp/cli.inherited" "$tmp/fd3"
export STUB_MODE=output STUB_OUTPUT="$tmp/forged-output" STUB_STDERR=$'model=forged-stderr\n' \
       STUB_ARGV="$tmp/cli.argv" STUB_PROMPT="$tmp/cli.prompt" STUB_INHERITED="$tmp/cli.inherited"
run_status python3 "$tmp/cli/scripts/vendor_adapters.py" invoke-answer \
  --role orchestrator_artifact_reviewer <"$tmp/prompt" \
  >"$tmp/cli.out" 2>"$tmp/cli.err" 3>"$tmp/fd3"
assert_status 'fd 3 open invocation' "$RUN_STATUS" 0
assert_cmp 'fd 3 exact model record including newline' "$tmp/expected-fd3" "$tmp/fd3"
[[ ! -e "$tmp/cli.inherited" ]] && ok 'fd 3 not inherited by vendor' || fail 'fd 3 inherited by vendor'
grep -F 'model=forged-stdout' "$tmp/cli.out" >/dev/null \
  && grep -F 'model=forged-stderr' "$tmp/cli.err" >/dev/null \
  && ok 'vendor model forgeries stay on stdout/stderr' || fail 'vendor forgery controls missing'
rm -f "$tmp/cli.inherited"
run_status python3 "$tmp/cli/scripts/vendor_adapters.py" invoke-answer \
  --role orchestrator_artifact_reviewer <"$tmp/prompt" >"$tmp/cli.out" 2>"$tmp/cli.err"
assert_status 'fd 3 absent invocation' "$RUN_STATUS" 0
[[ ! -e "$tmp/cli.inherited" ]] && ok 'fd 3 absent and vendor sees none' || fail 'absent fd 3 reached vendor'

run_status python3 scripts/vendor_adapters.py invoke-answer --role unsupported <"$tmp/prompt"
assert_status 'CLI usage error' "$RUN_STATUS" 99

# Slice 2: scripts/review consumes invoke-answer. Drive the committed base script itself rather
# than recreating either old vendor arm; missing fixture delimiters and bytes are guarded above.
configure_review() {
  local vendor=$1 effort=$2
  python3 - "$BASE/models.json" "$tmp/review-base/scripts/models.json" \
    "$tmp/review-cli/scripts/models.json" "$vendor" "$effort" <<'PY'
import json, sys
cfg = json.loads(open(sys.argv[1]).read())
model = "kimi-k3" if sys.argv[4] == "kimi" else "gpt-5.6-luna"
cfg["roles"]["orchestrator_artifact_reviewer"] = {
    "model": model, "effort": sys.argv[5]
}
data = json.dumps(cfg, indent=2) + "\n"
for path in sys.argv[2:4]:
    open(path, "w").write(data)
PY
}

run_review() {
  local side=$1 topic=$2
  run_status env ORCH_TEST_PY=python3 \
    "$tmp/review-$side/scripts/review" --topic "$topic" --author claude \
    --context "$tmp/review-context.txt" "review parity prompt" \
    >"$tmp/review-$side.stdout" 2>"$tmp/review-$side.outer"
  REVIEW_STATUS=$RUN_STATUS
}

rm -rf "$tmp/review-base/.orchestrator" "$tmp/review-cli/.orchestrator"
printf 'codex review answer\n' >"$tmp/codex-review-output"
printf '{"role":"assistant","content":"kimi review answer"}\n' >"$tmp/kimi-review-output"

# With high effort, Codex argv, stdin, recovered answer, and observable status stay byte-identical.
configure_review codex high
export STUB_MODE=output STUB_OUTPUT="$tmp/codex-review-output" STUB_STDERR=""
export STUB_ARGV="$tmp/review-base.argv" STUB_PROMPT="$tmp/review-base.prompt" \
       STUB_INHERITED="$tmp/review-base.inherited"
run_review base review-codex-high
base_review_status=$REVIEW_STATUS
export STUB_ARGV="$tmp/review-cli.argv" STUB_PROMPT="$tmp/review-cli.prompt" \
       STUB_INHERITED="$tmp/review-cli.inherited"
run_review cli review-codex-high
cli_review_status=$REVIEW_STATUS
assert_status 'review Codex high base' "$base_review_status" 0
assert_status 'review Codex high candidate' "$cli_review_status" 0
assert_cmp 'review Codex high complete argv' "$tmp/review-base.argv" "$tmp/review-cli.argv"
assert_cmp 'review Codex high prompt' "$tmp/review-base.prompt" "$tmp/review-cli.prompt"
assert_cmp 'review Codex high answer' \
  "$tmp/review-base/.orchestrator/reviews/review-codex-high/round-1.md" \
  "$tmp/review-cli/.orchestrator/reviews/review-codex-high/round-1.md"
[[ ! -e "$tmp/review-cli/.orchestrator/reviews/review-codex-high/round-1.raw" &&
   ! -e "$tmp/review-cli/.orchestrator/reviews/review-codex-high/round-1.md.partial" ]] \
  && ok 'review Codex success leaves no raw or partial' \
  || fail 'review Codex success left raw or partial'

# The base arm hard-coded high. A non-high fixture must move only the candidate's effort argv.
configure_review codex max
rm -f "$tmp/review-base.argv" "$tmp/review-cli.argv"
export STUB_ARGV="$tmp/review-base.argv" STUB_PROMPT="$tmp/review-base.prompt" \
       STUB_INHERITED="$tmp/review-base.inherited"
run_review base review-codex-max
base_review_status=$REVIEW_STATUS
export STUB_ARGV="$tmp/review-cli.argv" STUB_PROMPT="$tmp/review-cli.prompt" \
       STUB_INHERITED="$tmp/review-cli.inherited"
run_review cli review-codex-max
cli_review_status=$REVIEW_STATUS
assert_status 'review Codex non-high base' "$base_review_status" 0
assert_status 'review Codex non-high candidate' "$cli_review_status" 0
if python3 - "$tmp/review-base.argv" "$tmp/review-cli.argv" <<'PY'
from pathlib import Path
import sys
base = Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
candidate = Path(sys.argv[2]).read_bytes().split(b"\0")[:-1]
old, new = b"model_reasoning_effort=high", b"model_reasoning_effort=max"
assert base.count(old) == 1 and candidate.count(new) == 1
candidate[candidate.index(new)] = old
assert candidate == base
PY
then
  ok 'review Codex candidate carries configured non-high effort'
else
  fail 'review Codex non-high argv differs beyond configured effort'
fi
assert_cmp 'review Codex non-high prompt' "$tmp/review-base.prompt" "$tmp/review-cli.prompt"

# Kimi keeps the alias and every other argv byte; uniform printf adds exactly one prompt newline.
configure_review kimi max
export STUB_OUTPUT="$tmp/kimi-review-output"
rm -f "$tmp/review-base.argv" "$tmp/review-cli.argv"
export STUB_ARGV="$tmp/review-base.argv" STUB_PROMPT="$tmp/review-base.prompt" \
       STUB_INHERITED="$tmp/review-base.inherited"
run_review base review-kimi
base_review_status=$REVIEW_STATUS
export STUB_ARGV="$tmp/review-cli.argv" STUB_PROMPT="$tmp/review-cli.prompt" \
       STUB_INHERITED="$tmp/review-cli.inherited"
run_review cli review-kimi
cli_review_status=$REVIEW_STATUS
assert_status 'review Kimi base' "$base_review_status" 0
assert_status 'review Kimi candidate' "$cli_review_status" 0
if python3 - "$tmp/review-base.argv" "$tmp/review-cli.argv" \
    "$tmp/review-base.prompt" "$tmp/review-cli.prompt" <<'PY'
from pathlib import Path
import sys
base = Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
candidate = Path(sys.argv[2]).read_bytes().split(b"\0")[:-1]
base_prompt = Path(sys.argv[3]).read_bytes()
candidate_prompt = Path(sys.argv[4]).read_bytes()
assert candidate_prompt == base_prompt + b"\n"
assert base.count(b"-p") == candidate.count(b"-p") == 1
i, j = base.index(b"-p") + 1, candidate.index(b"-p") + 1
assert candidate[j] == base[i] + b"\n"
candidate[j] = base[i]
assert candidate == base
assert b"kimi-code/k3" in base
PY
then
  ok 'review Kimi argv preserves alias and adds exactly one prompt newline'
else
  fail 'review Kimi argv or prompt delta is not the frozen one-newline change'
fi
assert_cmp 'review Kimi recovered answer' \
  "$tmp/review-base/.orchestrator/reviews/review-kimi/round-1.md" \
  "$tmp/review-cli/.orchestrator/reviews/review-kimi/round-1.md"

# Vendor exits remain review exit 1 on both sides, including reserved statuses the CLI remaps.
configure_review codex high
export STUB_OUTPUT="$tmp/empty"
for code in 42 96 97 98 99; do
  export STUB_MODE=exit STUB_EXIT=$code
  export STUB_ARGV="$tmp/review-base-$code.argv" STUB_PROMPT="$tmp/review-base-$code.prompt" \
         STUB_INHERITED="$tmp/review-base-$code.inherited"
  run_review base "review-codex-exit-$code"
  base_review_status=$REVIEW_STATUS
  export STUB_ARGV="$tmp/review-cli-$code.argv" STUB_PROMPT="$tmp/review-cli-$code.prompt" \
         STUB_INHERITED="$tmp/review-cli-$code.inherited"
  run_review cli "review-codex-exit-$code"
  cli_review_status=$REVIEW_STATUS
  assert_status "review Codex vendor exit $code base" "$base_review_status" 1
  assert_status "review Codex vendor exit $code candidate" "$cli_review_status" 1
  assert_cmp "review Codex vendor exit $code argv" \
    "$tmp/review-base-$code.argv" "$tmp/review-cli-$code.argv"
  assert_cmp "review Codex vendor exit $code prompt" \
    "$tmp/review-base-$code.prompt" "$tmp/review-cli-$code.prompt"
done

# Pin the consumer's mapping for every CLI status directly. This includes a post-gate 99: the
# review config is valid, then the stubbed invoke-answer fails. Only recovery status 98 keeps raw.
cat >"$tmp/review-cli/scripts/vendor_adapters.py" <<'PY'
import os, pathlib, sys
args = sys.argv[1:]
raw = args[args.index("--raw") + 1]
pathlib.Path(raw).write_bytes(b"stub raw\n")
status = int(os.environ["STUB_CLI_STATUS"])
print(f"stub invoke-answer status {status}", file=sys.stderr)
raise SystemExit(status)
PY
export STUB_MODE=output STUB_STDERR=""
for code in 99 97 98 96 42; do
  topic="review-cli-status-$code"
  export STUB_CLI_STATUS=$code
  run_review cli "$topic"
  assert_status "review post-gate CLI status $code" "$REVIEW_STATUS" 1
  round_dir="$tmp/review-cli/.orchestrator/reviews/$topic"
  grep -F "invocation failed ($code); stderr at .orchestrator/reviews/$topic/round-1.stderr" \
      "$tmp/review-cli.outer" >/dev/null \
    && ok "review CLI status $code diagnostic names status and stderr" \
    || fail "review CLI status $code diagnostic missing status or stderr"
  grep -F "stub invoke-answer status $code" "$round_dir/round-1.stderr" >/dev/null \
    && ok "review CLI status $code retains stderr" \
    || fail "review CLI status $code lost stderr"
  [[ ! -e "$round_dir/round-1.md" && ! -e "$round_dir/round-1.md.partial" ]] \
    && ok "review CLI status $code mints no round or partial" \
    || fail "review CLI status $code minted round or partial"
  if [[ "$code" == 98 ]]; then
    [[ -e "$round_dir/round-1.md.raw" ]] \
      && ok 'review CLI status 98 retains raw' || fail 'review CLI status 98 lost raw'
  else
    [[ ! -e "$round_dir/round-1.md.raw" ]] \
      && ok "review CLI status $code removes raw" || fail "review CLI status $code retained raw"
  fi
done

# Invalid config is still caught by review's own first gate: exit 2 and no vendor/CLI launch.
cp scripts/vendor_adapters.py "$tmp/review-cli/scripts/vendor_adapters.py"
configure_review codex high
python3 - "$tmp/review-base/scripts/models.json" "$tmp/review-cli/scripts/models.json" <<'PY'
import json, sys
for path in sys.argv[1:]:
    cfg = json.load(open(path)); cfg["unexpected"] = True
    open(path, "w").write(json.dumps(cfg) + "\n")
PY
for side in base cli; do
  rm -f "$tmp/review-$side-invalid.argv" "$tmp/review-$side-invalid.prompt"
  export STUB_ARGV="$tmp/review-$side-invalid.argv" \
         STUB_PROMPT="$tmp/review-$side-invalid.prompt" \
         STUB_INHERITED="$tmp/review-$side-invalid.inherited"
  run_review "$side" "review-invalid-$side"
  assert_status "review invalid config $side" "$REVIEW_STATUS" 2
  [[ ! -e "$tmp/review-$side-invalid.argv" ]] \
    && ok "review invalid config $side launched no vendor" \
    || fail "review invalid config $side launched vendor"
done

if ((failures)); then
  printf 'vendor_cli_parity: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo 'vendor_cli_parity: PASS'
