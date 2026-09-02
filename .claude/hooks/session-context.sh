#!/usr/bin/env bash
# VENDORED FILE — canonical copy: dotfiles/home/claude/agent-hooks/session-context.sh
# Edit there and run sync-hooks.sh; pre-commit fails if this drifts.
#
# SessionStart — inject live git state; complements memini (semantic memory) and
# session-journal (task tracking).
#
# NOT `set -e`: this hook's whole job is to print context, and a non-zero exit makes
# Claude Code report "SessionStart hook error" while silently truncating whatever it
# had already emitted. Every command below is individually guarded instead.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
REPO_NAME=$(basename "$REPO_ROOT")

echo "=== ${REPO_NAME} Session Context ==="

BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "unknown")
echo "Branch: ${BRANCH:-unknown}"

UNCOMMITTED=$(git -C "$REPO_ROOT" status --short 2>/dev/null | head -10)
if [[ -n "$UNCOMMITTED" ]]; then
    echo "Uncommitted changes:"
    echo "$UNCOMMITTED"
else
    echo "Working tree: clean"
fi

echo "Last commit: $(git -C "$REPO_ROOT" log -1 --oneline 2>/dev/null || echo 'none')"

# Session journal current focus. The grep is guarded: a journal with no **Focus:** line
# is normal, and an unguarded `grep | sed` under pipefail exits 1 and kills the hook.
JOURNAL="$REPO_ROOT/.claude/session-journal.md"
if [[ -f "$JOURNAL" ]]; then
    FOCUS=$(grep -m1 '^\*\*Focus:\*\*' "$JOURNAL" 2>/dev/null | sed 's/\*\*Focus:\*\* //' || true)
    if [[ -n "$FOCUS" ]]; then
        echo "Last focus: $FOCUS"
    fi
fi

echo ""
echo "Note: For live cluster state use mcp-k8s tools. For past decisions use memini memory_recall."
echo "=== End Context ==="

exit 0
