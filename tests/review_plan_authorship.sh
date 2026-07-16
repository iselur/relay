#!/usr/bin/env bash
# Program C reshape (R84): two properties of scripts/review on PLAN-NNN artifacts, with a stub
# codex binary (no network, no real reviewer invoked).
#
# (1) Plan authorship derives from the .md frontmatter's author_model via the models.json
#     vendor_map — spec_author is a ROLE, not a vendor, so the old unconditional-codex namespace
#     rule would misclassify the moment the owner flips roles.spec_author in models.json. A
#     Claude-authored plan proceeds to Codex review; a Sol-authored plan is still refused as
#     self-review (exit 4); broken provenance (missing sibling .md, missing frontmatter, an
#     unmapped model) is refused outright, never guessed.
# (2) Review round dirs BIND to the artifact identity: a PLAN-NNN context forces --topic plan-nnn,
#     so a renamed topic can no longer mint a fresh directory and reset the 5-round cap.
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

cat >"$tmp/bin/codex" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null   # consume the stdin prompt like the real CLI
sleep "${CODEX_STUB_SLEEP:-0}"
printf 'stub review verdict\n'
STUB
chmod +x "$tmp/bin/codex"

cd "$tmp/repo"
export PATH="$tmp/bin:$PATH"

# Fixtures --------------------------------------------------------------------------------------
# Frontmatter exactly as scripts/codex-plan writes it; only author_model varies.
mk_plan() { # $1 path, $2 author_model
  printf -- '---\nid: %s\ncreated: 2026-07-16T00:00:00Z\nauthor_model: %s\nstatus: draft\ntask: "fixture"\n---\n# fixture plan body\n' \
    "$(basename "${1%.md}")" "$2" > "$1"
}
mkdir -p .orchestrator/plans
mk_plan .orchestrator/plans/PLAN-101.md claude-opus-4-8
mk_plan .orchestrator/plans/PLAN-001.md gpt-5.6-sol
printf '# no frontmatter at all\n' > .orchestrator/plans/PLAN-003.md
mk_plan .orchestrator/plans/PLAN-004.md mystery-model-9
mk_plan .orchestrator/plans/PLAN-105.md claude-opus-4-8
printf 'raw stdout provenance\n' > .orchestrator/plans/PLAN-105.stdout
printf 'orphan stdout, no sibling md\n' > .orchestrator/plans/PLAN-106.stdout
mk_plan .orchestrator/plans/PLAN-107.md claude-opus-4-8
printf 'a plain claude-drafted note\n' > claude-note.md
# Finding-1 fixtures: a Sol plan and a Claude plan copied to NON-reserved names. Content-based
# detection must classify from the frontmatter, so a rename cannot strip the recorded authorship.
mk_plan .orchestrator/plans/PLAN-201.md gpt-5.6-sol
cp .orchestrator/plans/PLAN-201.md sol-plan-renamed.md      # id: PLAN-201, sol, non-reserved name
mk_plan .orchestrator/plans/PLAN-202.md claude-opus-4-8
cp .orchestrator/plans/PLAN-202.md claude-plan-renamed.md   # id: PLAN-202, claude, non-reserved name
# Finding-2 fixtures: frontmatter parser laundering attempts. Written by hand (mk_plan can't emit
# malformed frontmatter): a stray trailing quote and a duplicate author_model key must NOT launder
# a Sol model into a 'claude' derivation — both refuse (exit 2), never guess.
printf -- '---\nid: PLAN-203\nauthor_model: gpt-5.6-sol'"'"'\nstatus: draft\n---\n# body\n' > stray-quote.md
printf -- '---\nid: PLAN-204\nauthor_model: gpt-5.6-sol\nauthor_model: claude-opus-4-8\nstatus: draft\n---\n# body\n' > dup-key.md
# Round-4 finding-1 fixture: an invalid UTF-8 byte (\xff) inside a duplicate author_model KEY. Under
# errors="replace" the byte was silently repaired into a DISTINCT key that dodged duplicate
# detection, so the plain `author_model: claude-opus-4-8` set the vendor and this Sol-value file
# derived 'claude'. Strict decoding treats invalid UTF-8 as broken provenance and refuses (exit 2).
printf -- '---\nid: PLAN-206\nauthor_model\xff: gpt-5.6-sol\nauthor_model: claude-opus-4-8\nstatus: draft\n---\n# body\n' > bad-utf8-dup.md
# Finding-3 fixtures: two distinct Sol plans (ordering — multiple-plan refusal must precede the
# codex self-review refusal), reusing PLAN-001 (sol) plus a second sol plan.
mk_plan .orchestrator/plans/PLAN-205.md gpt-5.6-sol
# Round-2 finding fixtures ----------------------------------------------------------------------
# R2-finding-3: a reserved PLAN-NNN name whose frontmatter id DISAGREES. A mismatched (or symlinked)
# sibling must never bind a stream artifact to the id its content claims — the reserved name and the
# content id must agree or refuse. PLAN-301.md declares id: PLAN-999; PLAN-301.stdout is its sibling.
printf -- '---\nid: PLAN-999\ncreated: 2026-07-16T00:00:00Z\nauthor_model: claude-opus-4-8\nstatus: draft\n---\n# mismatched-id body\n' > .orchestrator/plans/PLAN-301.md
printf 'stdout whose sibling .md lies about its id\n' > .orchestrator/plans/PLAN-301.stdout
# R2-finding-2: an INDENTED duplicate author_model. The col-0 key says claude; an indented second
# key says sol. The indented line must still count toward ambiguity — refuse, never take the first.
printf -- '---\nid: PLAN-302\nauthor_model: claude-opus-4-8\n author_model: gpt-5.6-sol\nstatus: draft\n---\n# body\n' > indented-dup.md
# R2-finding-4: an ORDINARY doc that merely carries an author_model key but no PLAN id is NOT a plan.
# It must keep its caller-chosen topic (behavior unchanged), not be refused as broken provenance.
printf -- '---\ntitle: design note\nauthor_model: claude-opus-4-8\n---\n# an ordinary claude doc with an author_model field\n' > doc-with-author.md
# Round-3 finding-1 fixtures: a PLAN file INSIDE a dispatch attempt. Its identity (and the round
# binding, name/id agreement, multiple-plan and topic checks) must still apply — a plan does not
# lose its id by sitting in an attempt dir. Each attempt records launch.json exactly as dispatch.py
# would; the plan's frontmatter author_model must AGREE with that worker_model's vendor or refuse.
mk_attempt_plan() { # $1 spec, $2 attempt-n, $3 worker_model, $4 plan-basename, $5 author_model
  local d=".orchestrator/attempts/$1/$2"
  mkdir -p "$d"
  printf '{"worker_model": "%s", "spec_id": "%s", "attempt": %s}\n' "$3" "$1" "$2" > "$d/launch.json"
  mk_plan "$d/$4.md" "$5"
}
mk_attempt_plan SPEC-401 1 claude-opus-4-8 PLAN-401 claude-opus-4-8   # claude attempt, claude plan (agree)
mk_attempt_plan SPEC-402 1 gpt-5.6-sol     PLAN-402 gpt-5.6-sol       # codex  attempt, sol   plan (agree)
mk_attempt_plan SPEC-403 1 claude-opus-4-8 PLAN-403 gpt-5.6-sol       # claude attempt, sol   plan (CONFLICT)
# Round-3 finding-2 fixtures: valid-YAML spellings a regex parser missed. A duplicate author_model
# written `author_model :` (space before colon) or `"author_model":` (quoted key) constructs the
# SAME mapping key as a plain one, so a real YAML parser sees the collision and refuses — the regex
# saw one occurrence and derived the first (claude) value, laundering a Sol plan. And a valid inline
# comment on the id (`id: PLAN-406 # comment`) must still be recognized as that PLAN, not dropped to
# a free topic — the comment is not part of the value.
printf -- '---\nid: PLAN-404\nauthor_model: claude-opus-4-8\nauthor_model : gpt-5.6-sol\nstatus: draft\n---\n# body\n' > space-colon-dup.md
printf -- '---\nid: PLAN-405\nauthor_model: claude-opus-4-8\n"author_model": gpt-5.6-sol\nstatus: draft\n---\n# body\n' > quoted-key-dup.md
printf -- '---\nid: PLAN-406 # allocation note\ncreated: 2026-07-16T00:00:00Z\nauthor_model: claude-opus-4-8\nstatus: draft\n---\n# body\n' > inline-comment.md

# 1. A Claude-authored plan (frontmatter author_model -> vendor claude) proceeds to Codex review
#    under its bound topic, and the round is recorded.
scripts/review --topic plan-101 --author claude --context .orchestrator/plans/PLAN-101.md "review" >/dev/null 2>&1 \
  && ok "claude-authored plan reviews under its bound topic" || bad "claude-authored plan refused under its bound topic"
[ -f .orchestrator/reviews/plan-101/round-1.md ] \
  && ok "round 1 recorded under plan-101" || bad "no round-1.md under plan-101"

# 2. Topic binding: the SAME artifact under any other topic is refused (exit 6) and writes nothing —
#    this is the rename-resets-cap bypass, closed.
for wrong in plan-102 fresh-slug-reset; do
  scripts/review --topic "$wrong" --author claude --context .orchestrator/plans/PLAN-101.md "review" >/dev/null 2>&1
  rc=$?
  [ "$rc" = 6 ] && ok "renamed topic '$wrong' refused (exit 6)" || bad "renamed topic '$wrong' gave exit $rc, expected 6"
  [ -e ".orchestrator/reviews/$wrong" ] && bad "renamed topic '$wrong' still created review state" \
    || ok "renamed topic '$wrong' writes nothing"
done

# 3. Legacy Sol-authored plan: derivation says codex. Matching --author codex hits the self-review
#    vendor gate (exit 4); forged --author claude hits the mismatch gate (exit 6).
scripts/review --topic plan-001 --author codex --context .orchestrator/plans/PLAN-001.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 4 ] && ok "sol-authored plan refused as self-review (exit 4)" || bad "sol-authored plan gave exit $rc, expected 4"
scripts/review --topic plan-001 --author claude --context .orchestrator/plans/PLAN-001.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "forged --author claude on a sol plan refused (exit 6)" || bad "forged claude on sol plan gave exit $rc, expected 6"

# 4. Broken provenance refuses outright (fail closed), never guesses:
scripts/review --topic plan-003 --author claude --context .orchestrator/plans/PLAN-003.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "plan without frontmatter refused (exit 2)" || bad "frontmatterless plan gave exit $rc, expected 2"
scripts/review --topic plan-004 --author claude --context .orchestrator/plans/PLAN-004.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "plan with unmapped author_model refused (exit 2)" || bad "unmapped author_model gave exit $rc, expected 2"
scripts/review --topic plan-106 --author claude --context .orchestrator/plans/PLAN-106.stdout "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "orphan .stdout without sibling .md refused (exit 2)" || bad "orphan .stdout gave exit $rc, expected 2"

# 5. A .stdout WITH its sibling .md derives from that sibling's frontmatter and binds the topic.
scripts/review --topic plan-105 --author claude --context .orchestrator/plans/PLAN-105.stdout "review" >/dev/null 2>&1 \
  && ok ".stdout derives claude from its sibling .md and reviews" || bad ".stdout with claude sibling refused"

# 6. Two distinct PLAN artifacts in one call are refused: one artifact per review, its rounds are
#    its cap.
scripts/review --topic plan-101 --author claude \
  --context .orchestrator/plans/PLAN-101.md --context .orchestrator/plans/PLAN-105.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "two distinct plan IDs refused (exit 2)" || bad "two plan IDs gave exit $rc, expected 2"

# 7. A plan plus a supporting non-plan file (both claude) still binds to the plan's topic.
scripts/review --topic plan-101 --author claude \
  --context .orchestrator/plans/PLAN-101.md --context claude-note.md "review" >/dev/null 2>&1 \
  && ok "plan + supporting note reviews under the bound topic" || bad "plan + supporting note refused"
scripts/review --topic side-slug --author claude \
  --context .orchestrator/plans/PLAN-101.md --context claude-note.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "plan + note under a renamed topic refused (exit 6)" || bad "plan + note renamed topic gave exit $rc, expected 6"

# 8. Non-plan contexts keep caller-chosen topics — behavior unchanged.
scripts/review --topic any-free-slug --author claude --context claude-note.md "review" >/dev/null 2>&1 \
  && ok "non-plan context keeps its caller-chosen topic" || bad "non-plan context refused under a free topic"

# 9. The 5-round cap holds for the BOUND topic under concurrency: six simultaneous invocations on
#    PLAN-107 (topic plan-107, rounds start fresh) must yield exactly five successes and one exit 3.
pids=()
for tag in a b c d e f; do
  CODEX_STUB_SLEEP=1 scripts/review --topic plan-107 --author claude \
    --context .orchestrator/plans/PLAN-107.md "concurrent $tag" >/dev/null 2>&1 & pids+=($!)
done
rcs=""
for p in "${pids[@]}"; do wait "$p"; rcs="$rcs $?"; done
rcs=$(echo "$rcs" | tr ' ' '\n' | sed '/^$/d' | sort -n | tr '\n' ' ' | sed 's/ $//')
[ "$rcs" = "0 0 0 0 0 3" ] && ok "bound-topic race: five successes, one refusal" || bad "bound-topic race statuses were '$rcs' (expected '0 0 0 0 0 3')"
n=$(find .orchestrator/reviews/plan-107 -name 'round-[0-9].md' | wc -l)
[ "$n" = 5 ] && ok "bound topic capped at 5 rounds under race" || bad "bound-topic race produced $n rounds (expected 5)"
# ...and the artifact cannot escape its spent cap through a rename (the exact old bypass).
scripts/review --topic plan-107-take2 --author claude --context .orchestrator/plans/PLAN-107.md "escape" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "spent-cap artifact cannot escape via topic rename (exit 6)" || bad "cap escape via rename gave exit $rc, expected 6"

# 10. FINDING 1 — a plan RENAMED to a non-reserved filename is still classified from its content,
#     not laundered by the rename. A Sol plan under a wrong name+topic derives codex → refused;
#     forged --author claude on it is a mismatch (exit 6, derived codex ≠ asserted claude).
scripts/review --topic sol-plan-renamed --author claude --context sol-plan-renamed.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "renamed Sol plan still derives codex (forged claude refused, exit 6)" \
  || bad "renamed Sol plan laundered: gave exit $rc, expected 6"
#     ...and it binds to its frontmatter id (PLAN-201), so even a matching --author codex under the
#     renamed topic is a cap-reset attempt (exit 6, the binding gate) — not self-review (exit 4).
scripts/review --topic sol-plan-renamed --author codex --context sol-plan-renamed.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "renamed Sol plan binds to its content id, renamed topic refused (exit 6)" \
  || bad "renamed Sol plan binding gave exit $rc, expected 6"
#     A renamed CLAUDE plan is not over-refused: it derives claude and proceeds under its bound topic.
scripts/review --topic plan-202 --author claude --context claude-plan-renamed.md "review" >/dev/null 2>&1 \
  && ok "renamed Claude plan derives claude and reviews under its bound topic" \
  || bad "renamed Claude plan refused under its bound topic"

# 11. FINDING 2 — the frontmatter parser cannot be laundered. A stray trailing quote and a duplicate
#     author_model key both refuse (exit 2); neither yields a 'claude' derivation from a Sol value.
scripts/review --topic plan-203 --author claude --context stray-quote.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "author_model with a stray unbalanced quote refused (exit 2)" \
  || bad "stray-quote author_model gave exit $rc, expected 2"
scripts/review --topic plan-204 --author claude --context dup-key.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "duplicate author_model keys refused (exit 2)" \
  || bad "duplicate author_model gave exit $rc, expected 2"

# 12. FINDING 3 — binding order. Two distinct Sol plans with --author codex must refuse as
#     multiple-plan (exit 2), NOT slip through to the codex self-review gate (exit 4).
scripts/review --topic plan-001 --author codex \
  --context .orchestrator/plans/PLAN-001.md --context .orchestrator/plans/PLAN-205.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "two distinct Sol plans refuse as multiple-plan before self-review (exit 2)" \
  || bad "two Sol plans with --author codex gave exit $rc, expected 2"
#     A single Sol plan with --author codex under a WRONG topic is a cap-reset attempt (exit 6, the
#     binding gate), NOT self-review (exit 4) — the exit code names the real reason.
scripts/review --topic wrong-topic --author codex --context .orchestrator/plans/PLAN-001.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "single Sol plan under a renamed topic refuses via binding (exit 6, not 4)" \
  || bad "single Sol plan renamed topic gave exit $rc, expected 6"

# 13. ROUND-2 FINDING 3 — a reserved PLAN-NNN name whose frontmatter id disagrees is refused
#     (exit 2): the name and the content id must agree, so a mismatched/symlinked sibling can never
#     move a stream artifact to a fresh round dir. Both the reserved .md and its .stdout refuse.
scripts/review --topic plan-301 --author claude --context .orchestrator/plans/PLAN-301.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "reserved .md whose frontmatter id disagrees refused (exit 2)" \
  || bad "reserved-name/id mismatch (.md) gave exit $rc, expected 2"
scripts/review --topic plan-301 --author claude --context .orchestrator/plans/PLAN-301.stdout "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "reserved .stdout whose sibling id disagrees refused (exit 2)" \
  || bad "reserved-name/id mismatch (.stdout) gave exit $rc, expected 2"

# 14. ROUND-2 FINDING 2 — an INDENTED duplicate author_model must not be ignored: it is ambiguous
#     provenance and refuses (exit 2), never taking the first (claude) value over the second (sol).
scripts/review --topic plan-302 --author claude --context indented-dup.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "indented duplicate author_model refused (exit 2)" \
  || bad "indented duplicate author_model gave exit $rc, expected 2"

# 15. ROUND-2 FINDING 4 — an ordinary doc carrying an author_model key but NO PLAN id is not a plan:
#     it keeps its caller-chosen topic (behavior unchanged), rather than being refused as broken.
scripts/review --topic any-free-doc --author claude --context doc-with-author.md "review" >/dev/null 2>&1 \
  && ok "doc with author_model but no PLAN id keeps its free topic" \
  || bad "doc with author_model but no PLAN id was refused"

# 16. ROUND-3 FINDING 1 — a PLAN file INSIDE a dispatch attempt keeps its identity: the round
#     binding, name/id checks, and vendor gates all still run. Previously derive_one returned from
#     the attempt branch with plan_id='-', so a Codex attempt exited 4 (self-review) without ever
#     binding the topic, and the same plan could be re-reviewed under fresh slugs.
#   (a) A Claude attempt hosting a Claude plan (frontmatter agrees) reviews under its bound topic...
scripts/review --topic plan-401 --author claude --context .orchestrator/attempts/SPEC-401/1/PLAN-401.md "review" >/dev/null 2>&1 \
  && ok "plan inside a claude attempt reviews under its bound topic" \
  || bad "plan inside a claude attempt refused under its bound topic"
[ -f .orchestrator/reviews/plan-401/round-1.md ] \
  && ok "round 1 recorded for the in-attempt claude plan" || bad "no round-1.md for the in-attempt claude plan"
#       ...and a renamed topic is refused (exit 6): the in-attempt plan is bound to its id.
scripts/review --topic attempt-plan-reslug --author claude --context .orchestrator/attempts/SPEC-401/1/PLAN-401.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "in-attempt plan under a renamed topic refused (exit 6)" \
  || bad "in-attempt plan renamed topic gave exit $rc, expected 6"
#   (b) A Codex attempt hosting a Sol plan under a WRONG topic hits the binding gate (exit 6) BEFORE
#       the self-review gate — the round-3 finding: binding now runs inside the attempt branch.
scripts/review --topic codex-attempt-reslug --author codex --context .orchestrator/attempts/SPEC-402/1/PLAN-402.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "in-attempt codex plan under a renamed topic refuses via binding (exit 6, not 4)" \
  || bad "in-attempt codex plan renamed topic gave exit $rc, expected 6"
#       ...and under its CORRECT bound topic it is the self-review gate (exit 4): derivation held.
scripts/review --topic plan-402 --author codex --context .orchestrator/attempts/SPEC-402/1/PLAN-402.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 4 ] && ok "in-attempt codex plan under its bound topic is self-review (exit 4)" \
  || bad "in-attempt codex plan bound topic gave exit $rc, expected 4"
#   (c) CONFLICT: a Claude attempt hosting a Sol-authored plan — the attempt's worker_model vendor and
#       the plan's frontmatter author_model vendor disagree. Ambiguous provenance refuses (exit 2),
#       so an attempt cannot host a foreign-vendor plan to launder its authorship.
scripts/review --topic plan-403 --author claude --context .orchestrator/attempts/SPEC-403/1/PLAN-403.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "in-attempt plan whose frontmatter vendor conflicts with the attempt refused (exit 2)" \
  || bad "in-attempt vendor conflict gave exit $rc, expected 2"
[ -e .orchestrator/reviews/plan-403 ] && bad "in-attempt conflict refusal still created review state" \
  || ok "in-attempt conflict refusal writes nothing"

# 17. ROUND-3 FINDING 2 — valid-YAML duplicate spellings a regex missed. `author_model :` (space
#     before colon) and `"author_model":` (quoted key) each construct the SAME mapping key as the
#     plain one, so a real parser sees the collision and refuses (exit 2) — never derives the first
#     (claude) value from a frontmatter that also carries a Sol author_model.
scripts/review --topic plan-404 --author claude --context space-colon-dup.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "space-before-colon duplicate author_model refused (exit 2)" \
  || bad "space-colon duplicate author_model gave exit $rc, expected 2"
scripts/review --topic plan-405 --author claude --context quoted-key-dup.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "quoted-key duplicate author_model refused (exit 2)" \
  || bad "quoted-key duplicate author_model gave exit $rc, expected 2"

# 18. ROUND-3 FINDING 2 (cont.) — a valid inline comment on the id (`id: PLAN-406 # note`) is still
#     recognized as PLAN-406 and bound, not dropped to a free topic. A non-reserved filename is used
#     so the recognition comes purely from the frontmatter: a wrong topic is refused (exit 6, bound),
#     and the correct plan-406 topic reviews.
scripts/review --topic free-not-bound --author claude --context inline-comment.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 6 ] && ok "id with an inline comment is still recognized and bound (wrong topic exit 6)" \
  || bad "id with inline comment gave exit $rc under a wrong topic, expected 6"
scripts/review --topic plan-406 --author claude --context inline-comment.md "review" >/dev/null 2>&1 \
  && ok "id with an inline comment reviews under its bound topic plan-406" \
  || bad "id with inline comment refused under its bound topic"

# 19. ROUND-4 FINDING 1 — invalid UTF-8 must not be silently repaired into a distinct key to dodge
#     duplicate detection. `author_model\xff:` + a plain `author_model: claude-opus-4-8` over a Sol
#     value derived 'claude' under errors="replace"; strict decoding refuses invalid UTF-8 (exit 2).
scripts/review --topic plan-206 --author claude --context bad-utf8-dup.md "review" >/dev/null 2>&1
rc=$?
[ "$rc" = 2 ] && ok "invalid UTF-8 in frontmatter refused, not repaired into a distinct key (exit 2)" \
  || bad "invalid UTF-8 frontmatter gave exit $rc, expected 2"

[ "$fails" -eq 0 ] && echo "PASS review_plan_authorship.sh" || echo "FAIL review_plan_authorship.sh"
exit "$fails"
