# BACKLOG — why we are here, and what is next

New ideas land here, never into flight; work starts only via `scripts/intake` with a definition of
done. Product work is tracked privately (owner 2026-07-17); this list carries only the harness itself.

## Why (the operator's own description of what this system is for)

A combination of an **AI engineering manager and AI engineers**: the orchestrator manages, judges,
reviews, and holds the trust boundary; the workers plan, research, implement, and test. The
capability the operator wants is end to end — drop an idea on it and it grills the idea, reconciles
a recommendation, breaks it into tickets, logs them, improves the plan, executes, reviews the
result, tests it, deploys it, and maintains what it ships. Every holistic review measures the setup
against this description: what matches, what doesn't, what is missing.

## Next up

- C3 salvage (grill verdict, 2026-08-06): replace the six duplicated open/flock/try/finally blocks
  in scripts/dispatch.py with one ~8-line `exclusive_lock` contextmanager (≈ −18 to −22 production
  lines; the box site keeps materialize-then-acquire ordering). Sketch in
  `.orchestrator/plans/C3-grill-verdict.md` §2.

- Remediation prompt vs. base reset (evidenced 2026-08-08, SPEC-054 attempt 4): a remediation
  attempt's worktree resets to `origin/ready-for-main`, but its prompt says "address these
  specific findings — nothing else". The worker re-implemented the script and shipped
  `tests/r102_benchmark.sh` byte-identical to base — 404 lines of the prior attempt's tests
  silently dropped — so the regression gate correctly refused a vacuous proof and the attempt
  burned. The prompt tells the worker it is editing a delta; the tree says it is starting over.
  Either hand the remediation attempt the prior attempt's commit as its base, or say plainly in
  the prompt that the tree is at base and the whole spec must be re-delivered with the findings
  fixed. Do not just re-word "nothing else" — the two halves have to agree.

(Other in-flight work lives in the private ledger, not here.)

The known security gaps are recorded in SECURITY.md and are deliberately NOT queued here: the owner
knows them, accepts them, and does not want them built (2026-08-06). Do not re-add them.

## Parked (owner 2026-07-16: keep for the future)

- In-flight session-to-session handoff (deferred in the lifecycle-program descope, owner
  2026-07-16): atomic handoff commit/consumption, duplicate suppression, mid-handoff crash
  recovery. If revived, rebuild in Python; the hardened scenario matrix is preserved on the
  lifecycle-falsifier branch.
- Measure whether review catches bugs: plant three known defects, count catches, size review scope from the result.
- External benchmark score and cost reporting — after a real product exists.
- R102 benchmark, STOPPED 2026-08-08 at the owner's word. One task, 1 trial per row
  (`terminal-bench/fix-git`, `.orchestrator/evidence/R102/kill-test/`), costs reconstructed from the
  retained raw role logs: vanilla Codex PASS $0.0101, vanilla Claude PASS $0.2253, harness with
  review OFF PASS $0.0354, production pairing FAIL $0.3799.
  - The production FAIL is a rig artifact, not a result. `scripts/r102_harness_agent.py:384` runs
    every role but the worker through `_subprocess_run` on the host, so the reviewer never reached
    the task container, and `_command` denies it every tool — one turn, zero tool calls, each round.
    Asked to judge a container it could not see from the worker's prose alone, it never emitted PASS
    (`_review_verdict` defaults to REVISE when neither token appears, and matches either anywhere in
    the text), so five rounds of blind remediation churned the worktree until both graded hashes
    missed. PASS was unreachable for that row. No trust-boundary breach: tools were denied and
    `permission_denials` is empty in all five rounds. Before any rerun, put the reviewer in the
    container or hand it the diff and test output. The same file also grades a never-reviewed
    post-cap artifact; both bugs are benchmark-only — production dispatch and review do not share it.
  - harness `usage.jsonl` keeps only plain input/output tokens, so Claude roles read as 1–7 input
    tokens; cache tokens and vendor cost survive in the per-role logs, which is where the figures
    above come from. Price from those, never from the manifest totals.
  - vanilla-kimi never started: `scripts/r102_tier_a.json:84` sends `kimi-k3` where Harbor's
    kimi-cli wants `provider/model_name`, and `kimi-code/k3` is already the alias in
    `scripts/models.json`. The owner does not need Kimi now (2026-08-08); one line restores it.
  `scripts/r102_benchmark.py` (preflight/kill-test/verify) is shipped and stays, default-off behind
  `R102_BENCHMARK=1`. PLAN-014, PLAN-015 and SPEC-054 are retired unmerged.
- Test the rendered reviewer EVIDENCE section (incl. spec-declared commands) directly instead of
  relying partly on a source-marker grep (harness-spec-command-evidence round 1, PASS backlog note).
- Relax scripts/review's model-level self-review refusal to instance/context level to match
  CLAUDE.md rule 7 (owner, 2026-08-06) — stricter-than-rule today, safe to keep until needed.
