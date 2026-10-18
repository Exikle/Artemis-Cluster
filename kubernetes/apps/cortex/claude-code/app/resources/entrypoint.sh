#!/usr/bin/env bash
# Start Claude Code Remote Control. Every step is idempotent; state lives on the PVC.
# Rationale and bootstrap: .agents/references/claude-code-remote.md
set -euo pipefail

REPO="$HOME/Artemis-Cluster"
MISE_VERSION=v2026.10.10
export PATH="$HOME/.local/bin:$PATH"

command -v mise >/dev/null || curl -fsSL https://mise.run | MISE_VERSION="$MISE_VERSION" sh
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash

install -D -m 600 /scripts/kubeconfig.yaml "$HOME/.kube/config"
install -D -m 644 /scripts/CLAUDE.md "$HOME/.claude/CLAUDE.md"

# dusk-bot authenticates git over HTTPS with the token from the environment.
git config --global user.name dusk-bot
git config --global user.email "171887436+dusk-bot[bot]@users.noreply.github.com"
# shellcheck disable=SC2016 # the token is expanded by git when it asks, not here
git config --global credential.https://git.dcunha.io.helper \
  '!f() { test "$1" = get && echo username=dusk-bot && echo "password=$FORGEJO_TOKEN"; }; f'
[ -d "$REPO/.git" ] || git clone https://git.dcunha.io/exikle/Artemis-Cluster.git "$REPO"

# Tools: pod-global pins (/scripts/mise.toml) plus the repo's own; PATH gets plain bin dirs
# so mise's repo env (KUBECONFIG, TALOSCONFIG) does not override the pod's.
cd "$REPO"
mise install || echo "WARN: mise install had failures"
PATH="$(mise bin-paths | paste -sd:):$PATH"
export PATH
hk install --mise >/dev/null 2>&1 || echo "WARN: hk install failed"

claude mcp get kubernetes >/dev/null 2>&1 \
  || claude mcp add -s user kubernetes -- kubernetes-mcp-server || true
claude mcp get flux-operator >/dev/null 2>&1 \
  || claude mcp add -s user flux-operator -- flux-operator-mcp serve || true
for marketplace in eleboucher/memini fluxcd/agent-skills home-operations/yayamlls ayghri/i-have-adhd; do
  claude plugin marketplace add "$marketplace" >/dev/null 2>&1 || true
done
for plugin in memini@memini gitops-skills@fluxcd yayamlls@yayamlls i-have-adhd@i-have-adhd; do
  claude plugin list 2>/dev/null | grep -q "$plugin" \
    || claude plugin install "$plugin" >/dev/null 2>&1 \
    || echo "WARN: plugin $plugin install failed"
done

# Login and workspace trust need a TTY once; idle until that bootstrap is done.
if [ ! -f "$HOME/.remote-control-ready" ]; then
  echo "claude-code: not bootstrapped; see .agents/references/claude-code-remote.md"
  exec sleep infinity
fi

git pull --ff-only -q || true

exec > >(perl /scripts/log-filter.pl) 2>&1
exec claude remote-control \
  --name artemis \
  --spawn worktree \
  --permission-mode default
