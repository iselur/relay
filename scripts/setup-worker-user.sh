#!/usr/bin/env bash
# D5 endgame — privileged, idempotent, run-once host setup for worker isolation.
#
# Closes residual risk 13-B: today the worker AND the gate test_command (which runs worker-produced
# code) run as `the operator` and can read ~/.config/gh/hosts.yml (gh token → can rewrite CI/push),
# ~/.codex/auth.json, ~/.claude*, ~/.ssh. This creates a dedicated `codex-worker` UID so FILESYSTEM
# PERMISSIONS — not Codex's read-porous sandbox (13-B: the Landlock legacy backend cannot restrict
# reads on this host) — separate worker actions from `the operator`'s credentials.
#
# Design: adversarially reviewed by Codex (record in git history),
# then corrected against what THIS box can actually enforce and proven empirically:
#   - dedicated system user `codex-worker` (no login, no sudo), private primary group, plus
#     supplementary group `codexwork` (traverse the shared worktree root).
#   - worktrees move OUT of the operator's home (0750 → unreachable by codex-worker) to /srv/codexwork.
#   - the worker + the gate test run as codex-worker in hardened `systemd-run --uid` SYSTEM services
#     (wired in scripts/dispatch.py): ProtectSystem=strict + ReadWritePaths=<worktree> confine
#     writes; InaccessiblePaths=the operator's home + DAC confine reads; the test service adds
#     PrivateNetwork=yes (it runs untrusted code and needs no API). Codex's own bwrap sandbox is
#     NOT used for the worker (it won't construct under the bind-mounted UID, and the user boundary
#     + systemd replace what it gave). Residual: the worker's model-commands keep network and can
#     read the worker's OWN copied codex token — NOT the operator's creds. Closing that needs per-attempt
#     UIDs or a credential broker (deferred). the operator's gh/ssh/claude creds are fully closed.
#   - the operator<->worker file handoff uses POSIX ACLs (not the shared group): the operator's long-running session
#     predates the group add, and ACLs let the operator read worker-created files without a re-login.
#
# Idempotent: safe to re-run. Requires passwordless sudo (the operator has it).
set -euo pipefail
say() { printf '\n== %s\n' "$*"; }

WORKER=codex-worker
GROUP=codexwork
WORKROOT=/srv/codexwork
WORKTREES=$WORKROOT/worktrees
WORKER_HOME=/home/$WORKER
TEST_RUNTIME=/opt/orchestrator-test-runtime

# The human operator whose credentials we isolate the worker FROM. Resolved explicitly (SOL: do NOT
# trust $(id -un) under sudo or $HOME under a sanitized env). Override with --operator-user/
# ORCH_OPERATOR_USER; default to the (non-root) invoking user. Home comes from the passwd database.
OPERATOR="${ORCH_OPERATOR_USER:-}"
[ -z "$OPERATOR" ] && for a in "$@"; do case "$a" in --operator-user=*) OPERATOR="${a#*=}";; esac; done
[ -z "$OPERATOR" ] && OPERATOR="$(id -un)"
if [ "$OPERATOR" = root ]; then
  echo "refuse: operator resolved to 'root'. Run WITHOUT sudo, or pass --operator-user=<name>." >&2
  exit 1
fi
OPERATOR_HOME="$(getent passwd "$OPERATOR" | cut -d: -f6)"
if [ -z "$OPERATOR_HOME" ] || [ ! -d "$OPERATOR_HOME" ]; then
  echo "refuse: cannot resolve home for operator '$OPERATOR' from passwd." >&2; exit 1
fi
echo "operator: $OPERATOR ($OPERATOR_HOME)"

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
sudo usermod -aG "$GROUP" "$OPERATOR"   # harmless; ACLs are what dispatch actually relies on
echo "$(id "$WORKER")"

say "3. worktree hierarchy (parent NOT group-writable → worker cannot create/rename siblings)"
sudo mkdir -p "$WORKTREES"
sudo chown root:root "$WORKROOT"; sudo chmod 0755 "$WORKROOT"
sudo chown "$OPERATOR":"$GROUP" "$WORKTREES"; sudo chmod 2750 "$WORKTREES"
echo "worktrees: $(stat -c '%a %U:%G' "$WORKTREES") $WORKTREES"

say "4. worker CODEX_HOME with the codex subscription auth (documented residual: worker's own token)"
WCODEX="$WORKER_HOME/.codex"
sudo mkdir -p "$WCODEX"
[ -f "$OPERATOR_HOME/.codex/auth.json" ] && sudo cp "$OPERATOR_HOME/.codex/auth.json" "$WCODEX/auth.json"
sudo chown -R "$WORKER":"$WORKER" "$WCODEX"
sudo chmod 700 "$WCODEX"; sudo find "$WCODEX" -type f -exec chmod 600 {} +
sudo chmod 750 "$WORKER_HOME"
echo "worker CODEX_HOME set (700 codex-worker; the operator cannot read it, nor can the worker read the operator)"

say "5. root-owned read-only Python runtime for isolated installed tests"
req_hash=$(sha256sum scripts/requirements.txt | awk '{print $1}')
installed_hash=$(sudo sh -c "cat '$TEST_RUNTIME/.requirements-sha256' 2>/dev/null || true")
if [ "$installed_hash" != "$req_hash" ]; then
  tmp_runtime="${TEST_RUNTIME}.new.$$"
  sudo rm -rf "$tmp_runtime"
  sudo python3 -m venv "$tmp_runtime"
  sudo "$tmp_runtime/bin/pip" install --disable-pip-version-check -r scripts/requirements.txt
  printf '%s\n' "$req_hash" | sudo tee "$tmp_runtime/.requirements-sha256" >/dev/null
  sudo chown -R root:root "$tmp_runtime"
  sudo chmod -R go-w "$tmp_runtime"
  sudo chmod 0755 "$tmp_runtime"
  sudo rm -rf "$TEST_RUNTIME"
  sudo mv "$tmp_runtime" "$TEST_RUNTIME"
fi
sudo test "$(sudo stat -c '%U:%G:%a' "$TEST_RUNTIME")" = "root:root:755"
sudo "$TEST_RUNTIME/bin/python" -c 'import yaml, jsonschema'
echo "test runtime: $(sudo stat -c '%a %U:%G' "$TEST_RUNTIME") $TEST_RUNTIME ($req_hash)"

say "6. sanity: worker is denied every operator credential (the whole point of D5)"
ok=1
for f in "$OPERATOR_HOME/.config/gh/hosts.yml" "$OPERATOR_HOME/.codex/auth.json" "$OPERATOR_HOME/.claude.json" "$OPERATOR_HOME/.ssh/id_ed25519"; do
  if sudo -u "$WORKER" cat "$f" >/dev/null 2>&1; then echo "  !!! $WORKER CAN READ $f"; ok=0; else echo "  denied: $f"; fi
done
[ "$ok" = 1 ] && echo "ALL operator credentials denied to $WORKER ✓" || { echo "SETUP FAILED — credential readable"; exit 1; }

say "DONE — foundation in place. Full isolation is PROVEN by tests/worker_isolation.sh."
