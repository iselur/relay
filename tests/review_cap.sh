#!/usr/bin/env bash
# The review-round cap must live in code: a prose cap already lost once to a ten-round review loop
# (~10,000 lines of revisions later replaced by a ~50-line hand fix). scripts/review allows three
# rounds per topic, refuses the fourth, counts ONLY round-N.md files as rounds (a sibling artifact
# once consumed a phantom round), refuses Codex-authored artifacts (its reviewer is Codex), and
# must hold the cap under concurrent invocations. Codex is always a local stub here.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo/scripts" "$tmp/repo/.orchestrator"
cp -p scripts/review "$tmp/repo/scripts/review"
# scripts/review reads $ROOT/scripts/models.json (reviewer model + vendor map) through
# $ROOT/scripts/models_check.py and fails closed without them; both sit beside the copied script.
cp -p scripts/models.json "$tmp/repo/scripts/models.json"
cp -p scripts/models_check.py "$tmp/repo/scripts/models_check.py"

cat >"$tmp/bin/codex" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null   # consume the stdin prompt like the real CLI
sleep "${CODEX_STUB_SLEEP:-0}"
printf 'stub review verdict\n'
STUB
chmod +x "$tmp/bin/codex"

cd "$tmp/repo"
export PATH="$tmp/bin:$PATH"

# Provenance fixtures (B18): scripts/review now DERIVES authorship from --context evidence instead
# of trusting --author, so every claude-authored call below needs a --context file that is NOT
# under a Codex-marked path (derives 'claude'), and the one codex-authored call needs a --context
# file inside a fake dispatch attempt (derives 'codex' from that attempt's own launch.json).
printf 'a plain claude-drafted note, not touching any Codex-marked path\n' > claude-note.md
mkdir -p .orchestrator/attempts/SPEC-900/1
printf '{"worker_model": "gpt-5.6-sol"}\n' > .orchestrator/attempts/SPEC-900/1/launch.json
printf 'fake codex worker diff\n' > .orchestrator/attempts/SPEC-900/1/diff.patch

# 1. Bad slugs and missing/unknown authors are refused.
if scripts/review --topic 'Bad Slug!' --author claude --context claude-note.md x 2>/dev/null; then bad "accepted a non-slug topic"; else ok "refuses a non-slug topic"; fi
if scripts/review --topic demo-topic --context claude-note.md x 2>/dev/null; then bad "accepted a review with no --author"; else ok "refuses a missing --author"; fi
if scripts/review --topic demo-topic --author gemini --context claude-note.md x 2>/dev/null; then bad "accepted an unknown author"; else ok "refuses an unknown author"; fi

# 2. Codex-authored artifacts are refused — the reviewer IS Codex, and Codex never grades Codex.
# (--author here MATCHES the derived provenance, so this exercises the vendor refusal, not B18's
# mismatch refusal — see tests/review_authorship.sh for the mismatch/no-provenance cases.)
scripts/review --topic demo-topic --author codex --context .orchestrator/attempts/SPEC-900/1/diff.patch "review this codex plan" >/dev/null 2>&1
rc=$?
[ "$rc" = 4 ] && ok "Codex-authored artifact refused (exit 4)" || bad "Codex-on-Codex not refused (exit $rc)"
[ -e .orchestrator/reviews/demo-topic ] && bad "refused author still created state" || ok "author refusal writes nothing"

# 3. Rounds 1-3 run and are recorded; sibling artifacts in the topic dir do NOT consume rounds.
scripts/review --topic demo-topic --author claude --context claude-note.md "round one prompt" >/dev/null 2>&1 \
  && ok "round 1 runs" || bad "round 1 failed"
printf 'author notes, not a review round\n' > .orchestrator/reviews/demo-topic/round-1-dispositions.md
scripts/review --topic demo-topic --author claude --context claude-note.md "round two prompt" >/dev/null 2>&1 \
  && ok "round 2 runs despite a round-1-*.md sibling artifact" || bad "sibling artifact consumed a phantom round"
scripts/review --topic demo-topic --author claude --context claude-note.md "round three prompt" >/dev/null 2>&1 \
  && ok "round 3 runs" || bad "round 3 failed"
n=$(find .orchestrator/reviews/demo-topic -name 'round-[0-9].md' | wc -l)
[ "$n" = 3 ] && ok "three rounds recorded" || bad "expected 3 recorded rounds, found $n"

# 4. Round 4 is refused with a distinct exit code and writes nothing.
scripts/review --topic demo-topic --author claude --context claude-note.md "round four prompt" >/dev/null 2>&1
rc=$?
[ "$rc" = 3 ] && ok "round 4 refused (exit 3)" || bad "round 4 not refused (exit $rc)"
n=$(find .orchestrator/reviews/demo-topic -name 'round-[0-9].md' | wc -l)
[ "$n" = 3 ] && ok "refusal wrote nothing" || bad "refusal still wrote a round file"

# 5. The cap holds under concurrency: of four simultaneous invocations on a fresh topic, exactly
#    three must SUCCEED and one must be REFUSED with exit 3 — filenames alone would not prove the
#    fourth process actually lost (bare `wait` discards statuses; the multiset is the evidence).
pids=()
CODEX_STUB_SLEEP=1 scripts/review --topic race-topic --author claude --context claude-note.md "concurrent a" >/dev/null 2>&1 & pids+=($!)
CODEX_STUB_SLEEP=1 scripts/review --topic race-topic --author claude --context claude-note.md "concurrent b" >/dev/null 2>&1 & pids+=($!)
CODEX_STUB_SLEEP=1 scripts/review --topic race-topic --author claude --context claude-note.md "concurrent c" >/dev/null 2>&1 & pids+=($!)
CODEX_STUB_SLEEP=1 scripts/review --topic race-topic --author claude --context claude-note.md "concurrent d" >/dev/null 2>&1 & pids+=($!)
rcs=""
for p in "${pids[@]}"; do wait "$p"; rcs="$rcs $?"; done
rcs=$(echo "$rcs" | tr ' ' '\n' | sed '/^$/d' | sort -n | tr '\n' ' ' | sed 's/ $//')
[ "$rcs" = "0 0 0 3" ] && ok "race statuses are exactly three successes and one refusal" || bad "race statuses were '$rcs' (expected '0 0 0 3')"
n=$(find .orchestrator/reviews/race-topic -name 'round-[0-9].md' | wc -l)
[ "$n" = 3 ] && ok "concurrent invocations still cap at 3 rounds" || bad "race produced $n rounds (expected exactly 3)"

# 7. Corrupt round states refuse rather than count: a gap lets the counter re-claim an existing
#    round and overwrite it forever (unlimited rounds); symlinks and directories are not rounds.
mkdir -p .orchestrator/reviews/gap-topic
printf 'stray round two\n' > .orchestrator/reviews/gap-topic/round-2.md
scripts/review --topic gap-topic --author claude --context claude-note.md "prompt" >/dev/null 2>&1
rc=$?
[ "$rc" = 5 ] && ok "gap state refused (exit 5)" || bad "gap state not refused (exit $rc)"
grep -q 'stray round two' .orchestrator/reviews/gap-topic/round-2.md \
  && ok "gap refusal overwrote nothing" || bad "gap refusal clobbered the existing round file"
mkdir -p .orchestrator/reviews/link-topic
printf 'real\n' > .orchestrator/reviews/link-topic/target.md
ln -s target.md .orchestrator/reviews/link-topic/round-1.md
scripts/review --topic link-topic --author claude --context claude-note.md "prompt" >/dev/null 2>&1
rc=$?
[ "$rc" = 5 ] && ok "symlink round refused (exit 5)" || bad "symlink round not refused (exit $rc)"
mkdir -p .orchestrator/reviews/dir-topic/round-1.md
scripts/review --topic dir-topic --author claude --context claude-note.md "prompt" >/dev/null 2>&1
rc=$?
[ "$rc" = 5 ] && ok "directory round refused (exit 5)" || bad "directory round not refused (exit $rc)"
mkdir -p .orchestrator/reviews/multi-topic
printf 'stray multi-digit round\n' > .orchestrator/reviews/multi-topic/round-10.md
scripts/review --topic multi-topic --author claude --context claude-note.md "prompt" >/dev/null 2>&1
rc=$?
[ "$rc" = 5 ] && ok "multi-digit stray round refused (exit 5)" || bad "round-10.md read as a clean directory (exit $rc)"

# 6. A different topic gets its own counter; empty prompts are refused.
scripts/review --topic other-topic --author claude --context claude-note.md "prompt" >/dev/null 2>&1 \
  && ok "independent counter per topic" || bad "second topic blocked by first topic's counter"
if printf '  \n' | scripts/review --topic empty-topic --author claude --context claude-note.md 2>/dev/null; then bad "accepted an empty prompt"; else ok "refuses an empty prompt"; fi

[ "$fails" -eq 0 ] && echo "PASS review_cap.sh" || echo "FAIL review_cap.sh"
exit "$fails"
