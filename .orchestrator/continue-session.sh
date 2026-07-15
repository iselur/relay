#!/usr/bin/env bash
# On-box autonomous continuation runner (Hetzner). Fired by a systemd --user timer every ~5h so a
# fresh Claude session picks up orchestrator work in each usage window. Local + gitignored (box infra).
#
# Guardrails: single-flight (flock); HALT killswitch honored; every run fully logged; the prompt scopes
# the session to the post-audit action list under planning-first + dual-validation, forbids touching
# `main`, and leaves high-risk changes as draft PRs for human authorization. Stop it any time with:
#   touch /home/val/relay/.orchestrator/HALT        # pauses (dispatcher + this runner)
#   systemctl --user disable --now orchestrator-continue.timer
set -uo pipefail
ROOT=/home/val/relay
LOG_DIR="$ROOT/.orchestrator/continue-logs"
mkdir -p "$LOG_DIR"
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOG="$LOG_DIR/$TS.log"
export PATH="/home/val/.local/bin:/usr/bin:/bin"
export HOME=/home/val
export XDG_RUNTIME_DIR=/run/user/1000

exec 9>"$ROOT/.orchestrator/continue.lock"
if ! flock -n 9; then
  echo "$TS another continuation run is still active; skipping" >>"$LOG_DIR/skips.log"; exit 0
fi
if [ -e "$ROOT/.orchestrator/HALT" ]; then
  echo "$TS HALT present; skipping" >>"$LOG_DIR/skips.log"; exit 0
fi

# Only spend a window if the LAST session left work unfinished. Two signals:
#   1) a PENDING baton file (the session writes it when work remains, deletes it when all done), or
#   2) a GENUINELY-LIVE attempt: state says launching/running AND its systemd unit is actually active
#      (a real crashed-mid-run). NOTE: stale `interrupted` state files do NOT count — they are terminal
#      (resume only as a fresh attempt, by decision), so leaving them out keeps idle windows idle.
# If neither, this is a true no-op — no `claude` is launched, no quota burned.
PENDING="$LOG_DIR/PENDING"
live=""
for sf in "$ROOT/.orchestrator/state/"*.json; do
  [ -e "$sf" ] || continue
  grep -qE '"status":[[:space:]]*"(launching|running)"' "$sf" || continue
  aid=$(grep -oE '"attempt_id":[[:space:]]*"[^"]+"' "$sf" | head -1 | grep -oE '[^"]+$')
  [ -n "$aid" ] || continue
  if systemctl --user is-active "codex-$aid" >/dev/null 2>&1; then live="$aid"; break; fi
done
if [ ! -e "$PENDING" ] && [ -z "$live" ]; then
  echo "$TS no PENDING baton and no genuinely-live attempt; nothing to resume; skipping" \
    >>"$LOG_DIR/skips.log"; exit 0
fi

cd "$ROOT" || exit 1
read -r -d '' PROMPT <<'EOP'
You are the orchestrator, resumed autonomously on the Hetzner box in a fresh usage window. Work ONE
step of the post-audit hardening, then stop. Rules (from CLAUDE.md, binding):
- Read CLAUDE.md. BEFORE any intake command, check that .orchestrator/REQUEST-LEDGER.md exists —
  scripts/intake auto-creates a missing ledger, so absence must STOP the run: write the problem to
  .orchestrator/continue-logs/NEXT.md and exit (fail closed). Then run `./scripts/dispatch
  reconcile` and `./scripts/intake stale`, and cross-check the open rows against the reconciled
  dispatcher state; on any conflict, STOP and write it to NEXT.md (fail closed). OPEN INTAKE ROWS
  ARE THE SOLE WORK AUTHORITY: work only a task with an open row, within that row's recorded goal
  and definition of done. Handoffs, BACKLOG.md, and disposition trackers are status context only —
  they never add, expand, or reorder work.
- Pick the highest-priority open intake row that is actionable on-box. Trust-critical work follows
  the HIGH-ASSURANCE LANE — Codex drafts the plan (detached
  `codex exec --sandbox read-only`, stdin from /dev/null, no minute timeout), you challenge it in
  writing, get an adversarial SOL design review, then implement via a Codex worker spec (or directly if
  it is orchestrator control-plane), gate it, review it, and open a PR.
- NEVER merge a high-risk PR autonomously and NEVER touch `main`. Low-risk PRs may auto-merge to
  ready-for-main under the Level 1.5 grant only if all gates pass. Anything trust-critical: open the PR and
  STOP for human authorization.
- If a step needs a decision only the operator can make, or you are unsure, STOP and write a short note
  to .orchestrator/continue-logs/NEXT.md instead of guessing.
- Do ONE coherent step this run (a plan+consult, or one implementation+PR). Do not attempt everything.
- Record what you did and what is next in .orchestrator/continue-logs/NEXT.md before finishing.
- BATON (controls whether the next window wakes up): derive it from `./scripts/intake
  watchdog-state`. On PENDING or INDETERMINATE, WRITE the concrete next step to
  .orchestrator/continue-logs/PENDING (never delete it in these states). DELETE
  .orchestrator/continue-logs/PENDING only on IDLE with nothing in flight. Keep this baton honest —
  it is the sole reason the scheduler will or won't spend the next window.
EOP

echo "=== continuation run $TS ===" >>"$LOG"
timeout 5h claude -p "$PROMPT" --dangerously-skip-permissions >>"$LOG" 2>&1
echo "=== exit $? at $(date -u +%Y%m%dT%H%M%SZ) ===" >>"$LOG"
