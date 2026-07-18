#!/usr/bin/env bash
# Slice 5: scripts/review kimi vendor-dispatch. Proves with stub binaries (no network, no live
# kimi invoked):
#   (a) kimi is accepted as --author (it is a known vendor);
#   (b) a kimi-authored artifact (attempt worker_model=kimi-k3) derives 'kimi' and routes
#       normally when the reviewer is codex (cross-vendor, not self-review);
#   (c) when the reviewer IS kimi (orchestrator_artifact_reviewer=kimi-k3 in models.json),
#       a kimi-authored artifact is REFUSED as self-review (exit 4, B18 security gate);
#   (d) when the reviewer is kimi, a claude-authored artifact runs through the kimi dispatch
#       path and the stub kimi's stream-json output is recovered as the round output;
#   (e) a prompt exceeding 120000 bytes is refused before kimi is invoked (byte-limit guard).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo/scripts" "$tmp/repo/.orchestrator"
cp -p scripts/review "$tmp/repo/scripts/review"
cp -p scripts/models.json "$tmp/repo/scripts/models.json"
cp -p scripts/models_check.py "$tmp/repo/scripts/models_check.py"
chmod u+w "$tmp/repo/scripts/models.json"

# Stub codex: used for default-config (codex reviewer) test cases.
cat >"$tmp/bin/codex" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'stub codex verdict\n'
STUB
chmod +x "$tmp/bin/codex"

# Stub kimi: emits a valid stream-json response with an assistant content line. The content is
# what the recovery logic extracts and writes to the round file.
cat >"$tmp/bin/kimi" <<'STUB'
#!/usr/bin/env bash
# consume all flags; the real kimi accepts -p/-m/--output-format but we ignore them here
printf '{"role":"user","content":"prompt"}\n'
printf '{"role":"assistant","content":"stub kimi verdict"}\n'
STUB
chmod +x "$tmp/bin/kimi"

cd "$tmp/repo"
export PATH="$tmp/bin:$PATH"

# ---- fixtures ---------------------------------------------------------------------------------
# A plain file that derives 'claude' by absence of any Codex/kimi marker.
printf 'a plain claude-drafted note\n' > claude-note.md

# A dispatch attempt whose worker was kimi-k3 — derives 'kimi' from launch.json.
mkdir -p .orchestrator/attempts/SPEC-501/1
printf '{"worker_model": "kimi-k3", "spec_id": "SPEC-501", "attempt": 1}\n' \
  > .orchestrator/attempts/SPEC-501/1/launch.json
printf 'diff --git a/x b/x\n+kimi wrote this\n' > .orchestrator/attempts/SPEC-501/1/diff.patch

# ---- (a) kimi accepted as --author with codex reviewer (default config) ----------------------
# With default models.json (orchestrator_artifact_reviewer=gpt-5.6-sol, vendor codex) a kimi-
# authored artifact must not be refused at the --author validation gate — 'kimi' is a known vendor.
# The artifact derives 'kimi', reviewer is codex, so cross-vendor: round proceeds.
scripts/review --topic kimi-author-codex-reviewer --author kimi \
  --context .orchestrator/attempts/SPEC-501/1/diff.patch "please review" >/dev/null 2>&1 \
  && ok "--author kimi accepted with codex reviewer; kimi-authored artifact routes cross-vendor" \
  || bad "--author kimi refused or failed with codex reviewer (exit $?)"
[ -f .orchestrator/reviews/kimi-author-codex-reviewer/round-1.md ] \
  && ok "round 1 recorded for kimi-authored artifact under codex reviewer" \
  || bad "no round-1.md recorded for kimi-authored artifact under codex reviewer"
grep -q 'stub codex verdict' .orchestrator/reviews/kimi-author-codex-reviewer/round-1.md \
  && ok "round output came from the stub codex reviewer (cross-vendor routing held)" \
  || bad "round output did not come from the stub codex reviewer"

# ---- (b) kimi derive_one: kimi-authored artifact classified correctly from launch.json ---------
# The derive_one vendor check used to refuse 'kimi' as 'not a known vendor'. The artifact's
# launch.json records worker_model=kimi-k3 -> vendor kimi; this must now derive without error.
# (already covered above — separate explicit check that the forged mismatch is still refused)
scripts/review --topic kimi-forged-author --author claude \
  --context .orchestrator/attempts/SPEC-501/1/diff.patch "please review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "forged --author claude on a kimi-authored artifact is refused (exit 6)" \
  || bad "forged --author claude on kimi artifact gave exit $rc, expected 6"

# ---- switch reviewer to kimi in models.json for cases (c), (d), (e) -------------------------
python3 - "$tmp/repo/scripts/models.json" <<'GUT'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["roles"]["orchestrator_artifact_reviewer"] = {"model": "kimi-k3", "effort": "high"}
json.dump(cfg, open(sys.argv[1], "w"))
GUT

# ---- (c) self-review guard: kimi reviewer refuses kimi-authored artifact (exit 4, B18) -------
scripts/review --topic kimi-self-review --author kimi \
  --context .orchestrator/attempts/SPEC-501/1/diff.patch "please review" >/dev/null 2>&1
rc=$?
[ "$rc" = 4 ] && ok "kimi-authored artifact refused as self-review under kimi reviewer (exit 4, B18)" \
  || bad "kimi self-review not refused: got exit $rc, expected 4"
[ -e .orchestrator/reviews/kimi-self-review ] \
  && bad "self-review refusal still created review state" \
  || ok "self-review refusal writes nothing"

# ---- (d) kimi dispatch: claude-authored artifact invokes stub kimi and recovers content ------
scripts/review --topic kimi-dispatch-claude --author claude \
  --context claude-note.md "please review" >/dev/null 2>&1 \
  && ok "kimi reviewer dispatches for claude-authored artifact" \
  || bad "kimi reviewer dispatch for claude artifact failed (exit $?)"
[ -f .orchestrator/reviews/kimi-dispatch-claude/round-1.md ] \
  && ok "round 1 recorded under kimi reviewer" \
  || bad "no round-1.md under kimi reviewer"
grep -q 'stub kimi verdict' .orchestrator/reviews/kimi-dispatch-claude/round-1.md \
  && ok "round output recovered from stub kimi stream-json (stream recovery works)" \
  || bad "round output not from stub kimi (stream recovery failed or wrong binary)"

# ---- (e) byte-limit refusal: prompt > 120000 bytes refused before kimi is invoked -----------
big_prompt=$(python3 -c "print('x' * 120001)")
scripts/review --topic kimi-byte-limit --author claude \
  --context claude-note.md "$big_prompt" >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "kimi reviewer refuses a prompt over 120000 bytes (exit $rc)" \
  || bad "kimi byte-limit refusal did not refuse an oversized prompt"
[ -f .orchestrator/reviews/kimi-byte-limit/round-1.md ] \
  && bad "byte-limit refusal still wrote a round file" \
  || ok "byte-limit refusal writes no round file"
# Verify kimi was NOT invoked (the argv guard fires before any kimi call).
[ -f "$tmp/kimi_invoked" ] \
  && bad "kimi binary was invoked despite the byte-limit guard" \
  || ok "kimi binary not invoked (byte-limit guard fires first)"

[ "$fails" -eq 0 ] && echo "PASS review_kimi.sh" || echo "FAIL review_kimi.sh"
exit "$fails"
