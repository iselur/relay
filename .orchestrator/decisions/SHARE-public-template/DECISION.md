# SHARE-public-template — make the existing repo a clean shareable template

**Tier:** Critical (credential/identity exposure remediation + public distribution + history rewrite
on protected branches). Val authorized: validate with SOL, proceed on the agreed approach, send link.

**SOL verdict:** BLOCK the original plan; PASS a corrected surgical version. Record: this dir
(prompt + response + events + sha256).

**Confirmed findings (Claude verified, agree with SOL):**
1. **Approvals bound ONLY to spec digest** (`approval_for(digest)`; only check is `spec_digest ==
   digest`). Copied approvals would authorize copied specs in a cloned repo → with a copied
   `AUTONOMY.json (enabled:true)`, a cloner's orchestrator could auto-dispatch + auto-merge Val's
   specs. MUST bind approvals to instance-id + repo identity; test that a copied approval is rejected.
   (Also a hardening of Val's own system.) BLOCKER for safe templating.
2. **Genericization via ambient env is unsafe.** `OPERATOR_USER=$(id -un)` is `root` under sudo;
   `$HOME` unreliable under systemd/sanitized env. Resolve operator from passwd/NSS; require explicit
   `--operator-user` for privileged setup; validate ownership; refuse `operator=root`/`home=/home/val`.
3. **Autonomy must be safe-by-DEFAULT**: track a DISABLED default; Val's enabled grant lives in a
   gitignored local override; migrate carefully so a merge never deletes his only live config.
4. History: surgical `git filter-repo` (rewrite ONLY the root-commit `Valentin Ryabtsev
   <iselur@gmail.com>` → noreply, + purge the 4 `sol-events.jsonl` paths). Squash BLOCK, broad
   identity rewrite BLOCK.
5. Provenance SHAs break on rewrite → move old evidence to `docs/project-provenance/pre-template/`,
   history-epoch policy, migration manifest (old→new SHA map) labeled derived-not-original.
6. Force-push: temporary NARROW bypass actor (`iselur`, `bypass_mode:always`), atomic
   `--force-with-lease` push of all affected refs/tags, restore + verify empty bypass. NOT
   delete/recreate. Token CAN admin the ruleset (verified: reads bypass_actors; `repo` scope + owner).
7. Val's live checkout will diverge → fresh sibling clone + atomic directory cutover with automation
   frozen; never `git pull`.
8. Missed surfaces to audit: all refs/tags/releases/PR-refs/issues/Actions-logs/wiki/Pages/forks,
   commit trailers, consultation RESPONSES + sha256.txt, workflow permissions (pull_request_target,
   unpinned actions), a real LICENSE (required for a usable template).
9. Template "include all branches" footgun → document "default branch only"; bootstrap creates
   `integration` from `main`.

**Claude disposition:** agree with all of SOL's corrections. One proportionality FORK is genuinely
Val's to set (SOL: "valid only if Val changes the requirement"): whether to rewrite the CANONICAL
repo's history (heavy/irreversible: force-push + live-box cutover) or take the lighter path where
only TEMPLATE-GENERATED copies are clean (fresh single-commit history) + `.mailmap` for display,
leaving the raw gmail in canonical deep history. Surfacing to Val before the irreversible step.
Safe reversible work (genericize, instance-bind approvals, safe-default autonomy, LICENSE,
README/BOOTSTRAP/init-operator, log-hygiene-at-tip, full surface audit) proceeds regardless.

**Verdicts:** SOL PASS (corrected plan). Claude PASS (corrected plan). Irreversible history step
pending Val's fork choice.
