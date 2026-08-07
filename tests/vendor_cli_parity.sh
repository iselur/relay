#!/usr/bin/env bash
# Byte/status oracle for invoke-answer and its codex-plan/review consumers. Base behavior is driven
# from committed snapshots; the test never reimplements a vendor arm.
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

# Slice 2: drive the committed review fixture and candidate review in separate git-less roots.
# Each side resolves only the scripts copied into its own root. Missing base review mechanics fail
# naturally and loudly; there is no fallback runner or recreated dispatch block.
mkdir -p "$tmp/review-base/scripts" "$tmp/review-cli/scripts"
cp "$BASE"/{review,models_check.py,models.json} "$tmp/review-base/scripts/"
cp scripts/{review,vendor_adapters.py} "$tmp/review-cli/scripts/"
cp "$BASE"/{models_check.py,models.json} "$tmp/review-cli/scripts/"
chmod +x "$tmp/review-base/scripts/review" "$tmp/review-cli/scripts/review"
printf 'review context without terminal newline' >"$tmp/review-base/context.md"
cp "$tmp/review-base/context.md" "$tmp/review-cli/context.md"

review_configure() {
  local vendor=$1 effort=$2
  python3 - "$BASE/models.json" "$tmp/review-base/scripts/models.json" \
    "$tmp/review-cli/scripts/models.json" "$vendor" "$effort" <<'PY'
import json, sys
cfg = json.loads(open(sys.argv[1]).read())
model = "kimi-k3" if sys.argv[4] == "kimi" else "gpt-5.6-luna"
cfg["roles"]["orchestrator_artifact_reviewer"] = {"model": model, "effort": sys.argv[5]}
data = json.dumps(cfg, indent=2) + "\n"
for path in sys.argv[2:4]:
    open(path, "w").write(data)
PY
}

run_review_pair() {
  local name=$1 vendor=$2 effort=$3 topic=$4 output=$5 mode=${6:-output} code=${7:-0}
  review_configure "$vendor" "$effort"
  rm -rf "$tmp/review-base/.orchestrator/reviews/$topic" \
         "$tmp/review-cli/.orchestrator/reviews/$topic"
  rm -f "$tmp"/{review-base.argv,review-cli.argv,review-base.prompt,review-cli.prompt,review-base.inherited,review-cli.inherited,review-base.out,review-cli.out,review-base.err,review-cli.err}
  export PATH="$tmp/bin:$PATH" STUB_MODE="$mode" STUB_EXIT="$code" STUB_OUTPUT="$output" STUB_STDERR=""
  export STUB_ARGV="$tmp/review-base.argv" STUB_PROMPT="$tmp/review-base.prompt" \
         STUB_INHERITED="$tmp/review-base.inherited"
  run_status env ORCH_TEST_PY=python3 "$tmp/review-base/scripts/review" --topic "$topic" \
    --author claude --context context.md 'review prompt' \
    >"$tmp/review-base.out" 2>"$tmp/review-base.err"
  REVIEW_BASE_STATUS=$RUN_STATUS
  export STUB_ARGV="$tmp/review-cli.argv" STUB_PROMPT="$tmp/review-cli.prompt" \
         STUB_INHERITED="$tmp/review-cli.inherited"
  run_status env ORCH_TEST_PY=python3 "$tmp/review-cli/scripts/review" --topic "$topic" \
    --author claude --context context.md 'review prompt' \
    >"$tmp/review-cli.out" 2>"$tmp/review-cli.err"
  REVIEW_CLI_STATUS=$RUN_STATUS
  [[ ! -e "$tmp/review-base.inherited" && ! -e "$tmp/review-cli.inherited" ]] \
    && ok "$name vendor did not inherit fd 3" || fail "$name vendor inherited fd 3"
}

assert_plus_newline() {
  local name=$1 base_file=$2 candidate_file=$3
  if python3 - "$base_file" "$candidate_file" <<'PY'
from pathlib import Path
import sys
base = Path(sys.argv[1]).read_bytes()
candidate = Path(sys.argv[2]).read_bytes()
raise SystemExit(0 if candidate == base + b"\n" else 1)
PY
  then
    ok "$name bytes"
  else
    fail "$name bytes are not base plus one newline"
  fi
}

assert_kimi_argv_plus_newline() {
  local name=$1 base_file=$2 candidate_file=$3
  if python3 - "$base_file" "$candidate_file" <<'PY'
from pathlib import Path
import sys
def argv(path):
    raw = Path(path).read_bytes()
    if not raw.endswith(b"\0"):
        raise SystemExit(1)
    return raw[:-1].split(b"\0")
base, candidate = argv(sys.argv[1]), argv(sys.argv[2])
if len(base) != len(candidate):
    raise SystemExit(1)
for index, (old, new) in enumerate(zip(base, candidate)):
    if index and base[index - 1] == b"-p":
        if new != old + b"\n":
            raise SystemExit(1)
    elif new != old:
        raise SystemExit(1)
PY
  then
    ok "$name bytes"
  else
    fail "$name differs beyond the prompt newline"
  fi
}

run_review_pair 'review Codex high success' codex high codex-high "$tmp/codex-output"
assert_status 'review Codex high base' "$REVIEW_BASE_STATUS" 0
assert_status 'review Codex high candidate' "$REVIEW_CLI_STATUS" 0
assert_cmp 'review Codex high complete argv' "$tmp/review-base.argv" "$tmp/review-cli.argv"
assert_cmp 'review Codex high prompt' "$tmp/review-base.prompt" "$tmp/review-cli.prompt"
assert_cmp 'review Codex high answer' \
  "$tmp/review-base/.orchestrator/reviews/codex-high/round-1.md" \
  "$tmp/review-cli/.orchestrator/reviews/codex-high/round-1.md"
[[ ! -e "$tmp/review-cli/.orchestrator/reviews/codex-high/round-1.md.raw" \
   && ! -e "$tmp/review-cli/.orchestrator/reviews/codex-high/round-1.md.partial" ]] \
  && ok 'review Codex success removed raw and partial' \
  || fail 'review Codex success retained raw or partial'

run_review_pair 'review Kimi success' kimi max kimi-success "$tmp/kimi-output"
assert_status 'review Kimi base' "$REVIEW_BASE_STATUS" 0
assert_status 'review Kimi candidate' "$REVIEW_CLI_STATUS" 0
assert_plus_newline 'review Kimi prompt adds exactly one newline' \
  "$tmp/review-base.prompt" "$tmp/review-cli.prompt"
assert_kimi_argv_plus_newline 'review Kimi argv otherwise identical (alias included)' \
  "$tmp/review-base.argv" "$tmp/review-cli.argv"
assert_cmp 'review Kimi answer' \
  "$tmp/review-base/.orchestrator/reviews/kimi-success/round-1.md" \
  "$tmp/review-cli/.orchestrator/reviews/kimi-success/round-1.md"
[[ ! -e "$tmp/review-cli/.orchestrator/reviews/kimi-success/round-1.md.raw" \
   && ! -e "$tmp/review-cli/.orchestrator/reviews/kimi-success/round-1.md.partial" ]] \
  && ok 'review Kimi success removed raw and partial' \
  || fail 'review Kimi success retained raw or partial'

# The base review hard-coded high; invoke-answer must instead carry the configured non-high effort.
run_review_pair 'review Codex configured effort' codex medium codex-medium "$tmp/codex-output"
grep -zFx 'model_reasoning_effort=high' "$tmp/review-base.argv" >/dev/null \
  && ok 'base review keeps hard-coded high effort' || fail 'base review high effort oracle missing'
grep -zFx 'model_reasoning_effort=medium' "$tmp/review-cli.argv" >/dev/null \
  && ok 'candidate review carries configured non-high effort' || fail 'candidate ignored configured effort'

run_review_pair 'review empty output' codex high review-empty "$tmp/empty"
assert_status 'review empty output base' "$REVIEW_BASE_STATUS" 1
assert_status 'review empty output candidate' "$REVIEW_CLI_STATUS" 1
[[ ! -e "$tmp/review-base/.orchestrator/reviews/review-empty/round-1.md" \
   && ! -e "$tmp/review-cli/.orchestrator/reviews/review-empty/round-1.md" \
   && ! -e "$tmp/review-cli/.orchestrator/reviews/review-empty/round-1.md.raw" \
   && ! -e "$tmp/review-cli/.orchestrator/reviews/review-empty/round-1.md.partial" ]] \
  && ok 'review empty output minted no round/raw/partial' \
  || fail 'review empty output left round/raw/partial'

# Every vendor/adapter failure remains review exit 1, retains stderr, and mints no round or raw file.
for vendor in codex kimi; do
  for code in 42 96 97 98 99; do
    topic="review-$vendor-exit-$code"
    run_review_pair "review $vendor vendor exit $code" "$vendor" \
      "$([[ $vendor == kimi ]] && echo max || echo high)" "$topic" "$tmp/empty" exit "$code"
    assert_status "review $vendor vendor exit $code base" "$REVIEW_BASE_STATUS" 1
    assert_status "review $vendor vendor exit $code candidate" "$REVIEW_CLI_STATUS" 1
    expected_cli_status=$code
    ((code < 96)) || expected_cli_status=96
    grep -F "invocation failed ($expected_cli_status)" "$tmp/review-cli.err" >/dev/null \
      && grep -F 'round-1.stderr' "$tmp/review-cli.err" >/dev/null \
      && ok "review $vendor vendor exit $code diagnostic names CLI status and stderr" \
      || fail "review $vendor vendor exit $code diagnostic incomplete"
    [[ -f "$tmp/review-base/.orchestrator/reviews/$topic/round-1.stderr" \
       && -f "$tmp/review-cli/.orchestrator/reviews/$topic/round-1.stderr" ]] \
      && ok "review $vendor vendor exit $code retained stderr" \
      || fail "review $vendor vendor exit $code lost stderr"
    [[ ! -e "$tmp/review-base/.orchestrator/reviews/$topic/round-1.md" \
       && ! -e "$tmp/review-cli/.orchestrator/reviews/$topic/round-1.md" \
       && ! -e "$tmp/review-cli/.orchestrator/reviews/$topic/round-1.md.raw" ]] \
      && ok "review $vendor vendor exit $code left no output/raw" \
      || fail "review $vendor vendor exit $code left output/raw"
  done
done

# Recovery failure is the sole raw-retention case on both old and new Kimi paths.
run_review_pair 'review Kimi recovery failure' kimi max kimi-recovery \
  "$tmp/kimi-review-malformed"
assert_status 'review Kimi recovery failure base' "$REVIEW_BASE_STATUS" 1
assert_status 'review Kimi recovery failure candidate' "$REVIEW_CLI_STATUS" 1
assert_cmp 'review Kimi recovery raw' \
  "$tmp/review-base/.orchestrator/reviews/kimi-recovery/round-1.md.raw" \
  "$tmp/review-cli/.orchestrator/reviews/kimi-recovery/round-1.md.raw"

# Review's own validated config gate precedes invoke-answer and every vendor subprocess.
review_configure codex high
python3 - "$tmp/review-base/scripts/models.json" "$tmp/review-cli/scripts/models.json" <<'PY'
import json, sys
cfg = json.loads(open(sys.argv[1]).read())
cfg["unexpected"] = True
data = json.dumps(cfg) + "\n"
for path in sys.argv[1:]:
    open(path, "w").write(data)
PY
rm -f "$tmp"/{review-base.argv,review-cli.argv,review-base.prompt,review-cli.prompt}
export STUB_ARGV="$tmp/review-base.argv" STUB_PROMPT="$tmp/review-base.prompt" \
       STUB_INHERITED="$tmp/review-base.inherited"
run_status env ORCH_TEST_PY=python3 "$tmp/review-base/scripts/review" --topic invalid-base \
  --author claude --context context.md review >"$tmp/review-base.out" 2>"$tmp/review-base.err"
assert_status 'review invalid config base' "$RUN_STATUS" 2
export STUB_ARGV="$tmp/review-cli.argv" STUB_PROMPT="$tmp/review-cli.prompt" \
       STUB_INHERITED="$tmp/review-cli.inherited"
run_status env ORCH_TEST_PY=python3 "$tmp/review-cli/scripts/review" --topic invalid-cli \
  --author claude --context context.md review >"$tmp/review-cli.out" 2>"$tmp/review-cli.err"
assert_status 'review invalid config candidate' "$RUN_STATUS" 2
[[ ! -e "$tmp/review-base.argv" && ! -e "$tmp/review-cli.argv" ]] \
  && ok 'review invalid config launched no vendor' || fail 'review invalid config launched vendor'

# Pin post-gate CLI status 99 independently of config validation.
review_configure codex high
cp "$tmp/review-cli/scripts/vendor_adapters.py" "$tmp/review-cli/scripts/vendor_adapters.real"
printf '%s\n' '#!/usr/bin/env python3' 'import sys' \
  'print("stub invoke-answer status 99", file=sys.stderr)' 'raise SystemExit(99)' \
  >"$tmp/review-cli/scripts/vendor_adapters.py"
run_status env ORCH_TEST_PY=python3 "$tmp/review-cli/scripts/review" --topic cli-status-99 \
  --author claude --context context.md review >"$tmp/review-cli.out" 2>"$tmp/review-cli.err"
assert_status 'review post-gate CLI 99 translation' "$RUN_STATUS" 1
grep -F 'invocation failed (99)' "$tmp/review-cli.err" >/dev/null \
  && grep -F 'round-1.stderr' "$tmp/review-cli.err" >/dev/null \
  && ok 'review post-gate CLI 99 diagnostic names status and stderr' \
  || fail 'review post-gate CLI 99 diagnostic incomplete'
grep -F 'stub invoke-answer status 99' \
  "$tmp/review-cli/.orchestrator/reviews/cli-status-99/round-1.stderr" >/dev/null \
  && ok 'review post-gate CLI 99 retained stderr' || fail 'review post-gate CLI 99 lost stderr'
[[ ! -e "$tmp/review-cli/.orchestrator/reviews/cli-status-99/round-1.md" \
   && ! -e "$tmp/review-cli/.orchestrator/reviews/cli-status-99/round-1.md.raw" ]] \
  && ok 'review post-gate CLI 99 minted no output/raw' \
  || fail 'review post-gate CLI 99 left output/raw'
mv "$tmp/review-cli/scripts/vendor_adapters.real" "$tmp/review-cli/scripts/vendor_adapters.py"

if ((failures)); then
  printf 'vendor_cli_parity: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo 'vendor_cli_parity: PASS'
