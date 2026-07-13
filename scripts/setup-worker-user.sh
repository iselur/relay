#!/usr/bin/env bash
# D5 endgame — privileged, idempotent, run-once host setup for worker isolation.
#
# Closes residual risk 13-B: today the worker AND the gate test_command (which runs worker-produced
# code) run as `val` and can read ~/.config/gh/hosts.yml (gh token → can rewrite CI/push),
# ~/.codex/auth.json, ~/.claude*, ~/.ssh. This creates a dedicated `codex-worker` UID so FILESYSTEM
# PERMISSIONS — not Codex's read-porous sandbox (13-B: the Landlock legacy backend cannot restrict
# reads on this host) — separate worker actions from `val`'s credentials.
#
# Design: validated adversarially with Codex SOL (.orchestrator/decisions/D5-worker-isolation/),
# then corrected against what THIS box can actually enforce and proven empirically:
#   - dedicated system user `codex-worker` (no login, no sudo), private primary group, plus
#     supplementary group `codexwork` (traverse the shared worktree root).
#   - worktrees move OUT of /home/val (0750 → unreachable by codex-worker) to /srv/codexwork.
#   - the worker + the gate test run as codex-worker in hardened `systemd-run --uid` SYSTEM services
#     (wired in scripts/dispatch.py): ProtectSystem=strict + ReadWritePaths=<worktree> confine
#     writes; InaccessiblePaths=/home/val + DAC confine reads; the test service adds
#     PrivateNetwork=yes (it runs untrusted code and needs no API). Codex's own bwrap sandbox is
#     NOT used for the worker (it won't construct under the bind-mounted UID, and the user boundary
#     + systemd replace what it gave). Residual: the worker's model-commands keep network and can
#     read the worker's OWN copied codex token — NOT val's creds. Closing that needs per-attempt
#     UIDs or a credential broker (deferred). Val's gh/ssh/claude creds are fully closed.
#   - val<->worker file handoff uses POSIX ACLs (not the shared group): val's long-running session
#     predates the group add, and ACLs let val read worker-created files without a re-login.
#
# Idempotent: safe to re-run. Requires passwordless sudo (val has it).
set -euo pipefail
say() { printf '\n== %s\n' "$*"; }

WORKER=codex-worker
GROUP=codexwork
WORKROOT=/srv/codexwork
WORKTREES=$WORKROOT/worktrees
WORKER_HOME=/home/$WORKER

say "1. packages: bubblewrap (distro), acl"
need=()
command -v bwrap  >/dev/null 2>&1 || need+=(bubblewrap)
command -v setfacl >/dev/null 2>&1 || need+=(acl)
if [ ${#need[@]} -gt 0 ]; then sudo apt-get update -qq; sudo apt-get install -y "${need[@]}"; fi
echo "bwrap $(/usr/bin/bwrap --version 2>/dev/null); acl $(setfacl --version 2>/dev/null | head -1)"

say "2. shared group + dedicated worker user (no login, no sudo)"
getent group "$GROUP" >/dev/null || sudo groupadd "$GROUP"
id "$WORKER" >/dev/null 2>&1 || sudo useradd --system --create-home --home-dir "$WORKER_HOME" \
     --shell /usr/sbin/nologin --user-group "$WORKER"
sudo usermod -aG "$GROUP" "$WORKER"
sudo usermod -aG "$GROUP" val   # harmless; ACLs are what dispatch actually relies on
echo "$(id "$WORKER")"

say "3. worktree hierarchy (parent NOT group-writable → worker cannot create/rename siblings)"
sudo mkdir -p "$WORKTREES"
sudo chown root:root "$WORKROOT"; sudo chmod 0755 "$WORKROOT"
sudo chown val:"$GROUP" "$WORKTREES"; sudo chmod 2750 "$WORKTREES"
echo "worktrees: $(stat -c '%a %U:%G' "$WORKTREES") $WORKTREES"

say "4. worker CODEX_HOME with the codex subscription auth (documented residual: worker's own token)"
WCODEX="$WORKER_HOME/.codex"
sudo mkdir -p "$WCODEX"
[ -f /home/val/.codex/auth.json ] && sudo cp /home/val/.codex/auth.json "$WCODEX/auth.json"
sudo chown -R "$WORKER":"$WORKER" "$WCODEX"
sudo chmod 700 "$WCODEX"; sudo find "$WCODEX" -type f -exec chmod 600 {} +
sudo chmod 750 "$WORKER_HOME"
echo "worker CODEX_HOME set (700 codex-worker; val cannot read it, nor can the worker read val)"

say "5. sanity: worker is denied every val credential (the whole point of D5)"
ok=1
for f in /home/val/.config/gh/hosts.yml /home/val/.codex/auth.json /home/val/.claude.json /home/val/.ssh/id_ed25519; do
  if sudo -u "$WORKER" cat "$f" >/dev/null 2>&1; then echo "  !!! $WORKER CAN READ $f"; ok=0; else echo "  denied: $f"; fi
done
[ "$ok" = 1 ] && echo "ALL val credentials denied to $WORKER ✓" || { echo "SETUP FAILED — credential readable"; exit 1; }

say "DONE — foundation in place. Full isolation is PROVEN by tests/worker_isolation.sh."
