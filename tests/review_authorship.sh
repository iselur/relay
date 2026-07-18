#!/usr/bin/env bash
# B18: scripts/review used to trust a caller-supplied --author string outright, so mislabeling a
# Codex-authored artifact as --author claude would route it to the Codex reviewer — self-review.
# Authorship must be DERIVED from dispatch/codex-plan provenance recorded on disk (launch.json
# worker_model, codex-plan's own output paths, recorded worker worktrees), never asserted by a
# flag. --author is now only a cross-check against that derived value. This test proves, with a
# stub codex binary (no network, no real Codex/Claude invoked):
#   (a) a forged --author that disagrees with recorded provenance is REFUSED (exit 6), never routed;
#   (b) a call with no provenance evidence at all is REFUSED (fail closed), never trusted;
#   (c) a correctly-derived, matching --author still runs and routes through the normal cap/reviewer
#       machinery (a claude-authored topic proceeds; a codex-authored topic is refused as self-review,
#       exit 4 — not because the flag said so, but because the derivation agreed).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo/scripts" "$tmp/repo/.orchestrator"
cp -p scripts/review "$tmp/repo/scripts/review"
# R71: scripts/review reads $ROOT/scripts/models.json (reviewer model + vendor_map) through
# $ROOT/scripts/models_check.py; the copied script's ROOT is the temp repo, so both sit beside it.
cp -p scripts/models.json "$tmp/repo/scripts/models.json"
cp -p scripts/models_check.py "$tmp/repo/scripts/models_check.py"
# dispatch integrate grades from a write-stripped tree; cp -p carries that read-only mode into
# this test's own scratch copy, which case 5 must rewrite — make the copy writable regardless.
chmod u+w "$tmp/repo/scripts/models.json"

cat >"$tmp/bin/codex" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null   # consume the stdin prompt like the real CLI; never actually invoked in this test
sleep "${CODEX_STUB_SLEEP:-0}"
printf 'stub review verdict\n'
STUB
chmod +x "$tmp/bin/codex"

cd "$tmp/repo"
export PATH="$tmp/bin:$PATH"

# Fixtures ------------------------------------------------------------------------------------
# A plain file that touches no Codex-marked path: derives 'claude' by absence of a Codex marker.
printf 'a claude-drafted analysis, never touched by Codex\n' > claude-note.md

# A real dispatch attempt, exactly as scripts/dispatch.py would record one: launch.json recording
# worker_model, written BEFORE any review call — this script must never write or trust this file,
# only read it. The diff file sits inside the attempt directory, as worker output would.
mkdir -p .orchestrator/attempts/SPEC-901/1
printf '{"worker_model": "gpt-5.6-sol", "spec_id": "SPEC-901", "attempt": 1}\n' \
  > .orchestrator/attempts/SPEC-901/1/launch.json
printf 'diff --git a/x b/x\n+codex wrote this\n' > .orchestrator/attempts/SPEC-901/1/diff.patch

# A recorded worker worktree (case 3 in scripts/review's derivation): a file living under the
# local worktree root dispatch.py hands to a non-isolated worker.
mkdir -p .worktrees/SPEC-902-1
printf 'codex worktree file, not tied to any attempt directory\n' > .worktrees/SPEC-902-1/notes.txt

# codex-plan's own output naming convention (case 2): only scripts/codex-plan writes this path,
# and it always writes frontmatter with author_model — the field authorship is derived from.
mkdir -p .orchestrator/plans
printf -- '---\nid: PLAN-001\nauthor_model: gpt-5.6-sol\nstatus: draft\n---\n# codex-drafted plan\n' \
  > .orchestrator/plans/PLAN-001.md

# A GENUINE codex-plan artifact written via `--out DIR` OUTSIDE .orchestrator/plans. scripts/codex-plan
# takes --out and writes the same reserved PLAN-NNN naming anywhere; keying authorship on the
# directory would let this real Codex artifact derive 'claude' and be laundered through --author.
mkdir -p custom-out/nested
printf -- '---\nid: PLAN-042\nauthor_model: gpt-5.6-sol\nstatus: draft\n---\n# codex plan via --out\n' \
  > custom-out/nested/PLAN-042.md
printf 'raw stdout\n' > custom-out/nested/PLAN-042.stdout

# 1a. FORGED --author: a Codex-attempt-linked artifact (real provenance says codex) labeled
#     --author claude must be REFUSED — never routed to the Codex reviewer as a "claude" artifact,
#     and never silently accepted as codex either (the caller's assertion disagreed with the record).
scripts/review --topic forged-attempt --author claude --context .orchestrator/attempts/SPEC-901/1/diff.patch "please review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "forged --author claude on a Codex-attempt artifact is refused (exit 6)" \
  || bad "forged --author claude on a Codex-attempt artifact NOT refused (exit $rc)"
[ -e .orchestrator/reviews/forged-attempt ] && bad "forged-author refusal still created review state" \
  || ok "forged-author refusal writes nothing"

# 1b. Same forgery via a recorded worker worktree file instead of an attempt directory.
scripts/review --topic forged-worktree --author claude --context .worktrees/SPEC-902-1/notes.txt "please review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "forged --author claude on a worker-worktree artifact is refused (exit 6)" \
  || bad "forged --author claude on a worker-worktree artifact NOT refused (exit $rc)"

# 1c. Same forgery via codex-plan output (default .orchestrator/plans location).
scripts/review --topic forged-plan --author claude --context .orchestrator/plans/PLAN-001.md "please review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "forged --author claude on codex-plan output is refused (exit 6)" \
  || bad "forged --author claude on codex-plan output NOT refused (exit $rc)"

# 1c-bis. THE FINDING-1 REGRESSION: a genuine codex-plan artifact written via --out to a NON-default
#     directory must still derive 'codex' by its reserved PLAN-NNN naming, so a forged --author
#     claude on it is refused. Directory-keyed classification would have let this through.
scripts/review --topic forged-plan-out --author claude --context custom-out/nested/PLAN-042.md "please review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "forged --author claude on a --out plan outside .orchestrator/plans is refused (exit 6)" \
  || bad "forged --author claude on a --out plan (PLAN-042.md in custom dir) NOT refused (exit $rc)"
scripts/review --topic forged-plan-out-stdout --author claude --context custom-out/nested/PLAN-042.stdout "please review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "forged --author claude on a --out plan's .stdout is refused (exit 6)" \
  || bad "forged --author claude on a --out plan .stdout NOT refused (exit $rc)"

# 1d. The reverse forgery also refused: a plain claude-authored file mislabeled --author codex.
scripts/review --topic forged-reverse --author codex --context claude-note.md "please review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "forged --author codex on a claude-authored artifact is refused (exit 6)" \
  || bad "forged --author codex on a claude-authored artifact NOT refused (exit $rc)"

# 2. MISSING PROVENANCE: no --context at all means nothing to derive from — refuse rather than
#    trust the --author string alone (this is the exact B18 bug: a bare, caller-supplied claim).
scripts/review --topic no-provenance --author claude "please review" >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "no --context evidence is refused rather than trusted (exit $rc)" \
  || bad "a bare --author claim with no evidence was accepted"
[ -e .orchestrator/reviews/no-provenance ] && bad "missing-provenance refusal still created review state" \
  || ok "missing-provenance refusal writes nothing"

# Also refused when context files disagree with each other (ambiguous provenance) — this must not
# resolve by picking one side.
scripts/review --topic mixed-provenance --author claude \
  --context claude-note.md --context .orchestrator/attempts/SPEC-901/1/diff.patch \
  "please review" >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "mixed-provenance context files are refused rather than resolved (exit $rc)" \
  || bad "mixed-provenance context files were silently accepted"

# 3. CORRECT DERIVATION routes normally:
#    - claude-authored evidence + matching --author claude proceeds to the normal round machinery.
scripts/review --topic real-claude-topic --author claude --context claude-note.md "please review" >/dev/null 2>&1 \
  && ok "correctly-derived claude authorship runs round 1" || bad "correctly-derived claude authorship failed to run"
[ -f .orchestrator/reviews/real-claude-topic/round-1.md ] \
  && ok "round 1 output was written for the correctly-derived claude topic" \
  || bad "no round-1.md written for the correctly-derived claude topic"
grep -q 'stub review verdict' .orchestrator/reviews/real-claude-topic/round-1.md \
  && ok "round 1 output came from the (stub) Codex reviewer, i.e. cross-vendor routing held" \
  || bad "round 1 output did not come from the stub reviewer"

#    - codex-attempt evidence + matching --author codex is refused as self-review (exit 4, not 6):
#      the derivation and the flag AGREE this time, so this exercises the vendor gate, not the
#      mismatch gate — proving the fix didn't just relabel every refusal as a mismatch.
scripts/review --topic real-codex-topic --author codex --context .orchestrator/attempts/SPEC-901/1/diff.patch "please review" >/dev/null 2>&1
rc=$?
[ "$rc" = 4 ] && ok "correctly-derived codex authorship is refused as self-review (exit 4)" \
  || bad "correctly-derived codex authorship gave exit $rc, expected 4 (self-review vendor gate)"
[ -e .orchestrator/reviews/real-codex-topic ] && bad "self-review refusal still created review state" \
  || ok "self-review refusal writes nothing"

# 4. UNRECOGNIZED MODEL (owner decision 2026-07-18): an attempt whose recorded worker_model
#    matches no vendor_patterns falls through to the sandboxed default (codex), never refused.
#    With --author codex the derivation agrees, so the codex self-review gate refuses (exit 4) —
#    proving the model was actually classified as codex, not refused for being unrecognized.
mkdir -p .orchestrator/attempts/SPEC-903/1
printf '{"worker_model": "mystery-model-9", "spec_id": "SPEC-903", "attempt": 1}\n' \
  > .orchestrator/attempts/SPEC-903/1/launch.json
printf 'diff --git a/y b/y\n+mystery model wrote this\n' > .orchestrator/attempts/SPEC-903/1/diff.patch
scripts/review --topic unknown-model --author codex --context .orchestrator/attempts/SPEC-903/1/diff.patch "please review" >/dev/null 2>&1
rc=$?
[ "$rc" = 4 ] && ok "unrecognized worker_model defaults to codex (sandboxed); self-review gate refuses (exit 4)" \
  || bad "unrecognized worker model gave exit $rc, expected 4 (codex default, self-review)"
[ -e .orchestrator/reviews/unknown-model ] && bad "self-review refusal still created review state" \
  || ok "self-review refusal writes nothing"

# 5. WHOLE-CONFIG VALIDATION (round-1 review): a config missing a required section — vendor_patterns
#    here — must refuse the review at startup, even for an ordinary claude-authored context that
#    never needs a vendor lookup. Only the one jq-style value being present is NOT enough.
python3 - "$tmp/repo/scripts/models.json" <<'GUT'
import json, sys
cfg = json.load(open(sys.argv[1])); del cfg["vendor_patterns"]
json.dump(cfg, open(sys.argv[1], "w"))
GUT
scripts/review --topic gutted-config --author claude --context claude-note.md "please review" >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "config without vendor_patterns refuses the review outright (exit $rc)" \
  || bad "a config missing vendor_patterns still ran a review"
[ -e .orchestrator/reviews/gutted-config ] && bad "gutted-config refusal still created review state" \
  || ok "gutted-config refusal writes nothing"
# restore for any later cases, still writable ($ROOT may be a write-stripped grader tree)
cp "$ROOT/scripts/models.json" scripts/models.json
chmod u+w scripts/models.json

[ "$fails" -eq 0 ] && echo "PASS review_authorship.sh" || echo "FAIL review_authorship.sh"
exit "$fails"
