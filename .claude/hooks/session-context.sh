#!/usr/bin/env bash
# SessionStart — inject live git state; complements memini (semantic memory) and session-journal (task tracking)
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

echo "=== Artemis-Cluster Session Context ==="

# Git state
BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "unknown")
echo "Branch: $BRANCH"

UNCOMMITTED=$(git -C "$REPO_ROOT" status --short 2>/dev/null | head -10)
if [[ -n "$UNCOMMITTED" ]]; then
    echo "Uncommitted changes:"
    echo "$UNCOMMITTED"
else
    echo "Working tree: clean"
fi

# Last commit
echo "Last commit: $(git -C "$REPO_ROOT" log -1 --oneline 2>/dev/null || echo 'none')"

# Session journal current focus
JOURNAL="$REPO_ROOT/.claude/session-journal.md"
if [[ -f "$JOURNAL" ]]; then
    FOCUS=$(grep -m1 "^\*\*Focus:\*\*" "$JOURNAL" | sed 's/\*\*Focus:\*\* //')
    [[ -n "$FOCUS" ]] && echo "Last focus: $FOCUS"
fi

echo ""
echo "Note: For live cluster state use mcp-k8s tools. For past decisions use memini memory_recall."
echo "=== End Context ==="
