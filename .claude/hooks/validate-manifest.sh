#!/usr/bin/env bash
# PostToolUse:Edit|Write|MultiEdit — YAML lint on kubernetes manifests after edits
set -euo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")

# Only process YAML files inside kubernetes/
[[ "$FILE" =~ \.ya?ml$ ]] || exit 0
[[ "$FILE" =~ /kubernetes/ ]] || exit 0

ERRORS=()

# yamllint (available via mise)
YAMLLINT=$(mise exec -- which yamllint 2>/dev/null || which yamllint 2>/dev/null || echo "")
if [[ -n "$YAMLLINT" ]]; then
    if ! YAMLLINT_OUT=$(mise exec -- yamllint -d relaxed "$FILE" 2>&1); then
        ERRORS+=("yamllint: $YAMLLINT_OUT")
    fi
fi

# oxfmt check (format validation only, not enforcement)
OXFMT=$(mise exec -- which oxfmt 2>/dev/null || which oxfmt 2>/dev/null || echo "")
if [[ -n "$OXFMT" ]]; then
    if ! OXFMT_OUT=$(mise exec -- oxfmt check "$FILE" 2>&1); then
        ERRORS+=("oxfmt: $OXFMT_OUT")
    fi
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "Validation warnings for $FILE:"
    for err in "${ERRORS[@]}"; do
        echo "  $err"
    done
    # Exit 1 (non-blocking) — warn Claude but don't block the edit
    exit 1
fi

exit 0
