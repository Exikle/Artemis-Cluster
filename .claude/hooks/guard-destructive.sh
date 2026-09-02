#!/usr/bin/env bash
# GENERATED FILE — do not edit here.
# Source:     .claude/hooks/guard-rules.json  (canonical: dotfiles/home/claude/agent-hooks/)
# Regenerate: python3 .claude/hooks/gen-guards.py
# Verified:   python3 .claude/hooks/gen-guards.py --check   (runs in pre-commit)
#
# PreToolUse:Bash — blocks destructive cluster operations that bypass GitOps or
# the sanctioned just commands.

# The rule patterns are single-quoted regexes, so a literal \$HOME in one is deliberate —
# it must reach grep unexpanded. shellcheck reads it as a missed expansion.
# shellcheck disable=SC2016
set -euo pipefail

INPUT=$(cat)

# Fast path: skip the Python pass entirely when no rule below can possibly fire.
# The stripped command is always a subset of this raw payload, so a keyword absent
# here cannot appear in it. Saves ~60ms of interpreter startup on Bash calls that
# match no rule at all, which is most of them.
[[ "$INPUT" =~ (kubectl|helm|flux|talosctl|(^|[^[:alnum:]_])rm[^[:alnum:]_]) ]] || exit 0

# Strip heredoc BODIES before any rule sees the command; the opening line is kept,
# so the real command on it (git commit -F - <<'MSG', python3 <<PY, ...) is checked.
COMMAND=$(printf '%s' "$INPUT" | python3 -c 'import sys, json, re
try:
    cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
except Exception:
    print(""); sys.exit(0)
lines = cmd.split("\n")
kept, i = [], 0
start = re.compile(r"<<-?[ \t]*([\x27\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
while i < len(lines):
    line = lines[i]
    kept.append(line)
    i += 1
    for _q, delim in start.findall(line):
        while i < len(lines) and lines[i].strip() != delim:
            i += 1
        if i < len(lines):
            i += 1
print("\n".join(kept))' 2>/dev/null || echo "")

block() {
    # Must be stderr: a PreToolUse hook's exit-2 reason only reaches the model on
    # stderr. On stdout the call is still refused but the explanation is dropped,
    # surfacing as "No stderr output".
    echo "BLOCKED: $1" >&2
    echo "Alternative: $2" >&2
    exit 2
}

# Read-only validation is always fine
printf '%s' "$COMMAND" | grep -qE -- --dry-run && exit 0

# kubectl-apply
if printf '%s' "$COMMAND" | grep -qE -- '\bkubectl\b.*\bapply\b'; then
    block 'Direct kubectl apply bypasses GitOps' 'Use '"'"'just kube apply-ks <ns> <ks>'"'"' to apply changes via Flux'
fi

# kubectl-delete-critical
if printf '%s' "$COMMAND" | grep -qE -- '\bkubectl\b.*\bdelete\b.*\b(namespace|pvc|pv|persistentvolumeclaim|node|deployment|secret|helmrelease|kustomization|gateway|httproute|clusterrole)\b'; then
    block 'Deleting a critical Kubernetes resource' 'Confirm with the user before deleting cluster resources'
fi

# helm-mutation
if printf '%s' "$COMMAND" | grep -qE -- '\bhelm\b.*\b(install|upgrade|uninstall|delete|rollback)\b'; then
    block 'Direct helm mutations are not allowed — config lives in HelmRelease manifests' 'Edit the HelmRelease values and apply via Flux'
fi

# flux-destructive
if printf '%s' "$COMMAND" | grep -qE -- '\bflux\b.*\b(delete|uninstall)\b'; then
    block 'Destructive flux operation' 'Confirm with the user before deleting Flux resources'
fi

# talosctl-patch-machineconfig
if printf '%s' "$COMMAND" | grep -qE -- '\btalosctl\b.*patch\s+machineconfig\b'; then
    block 'talosctl patch machineconfig duplicates array fields (machine.files etc.) and can brick the node' 'Use '"'"'just talos apply-node <node>'"'"' or talosctl apply-config --file for full config replacement'
fi

# talosctl-reset
if printf '%s' "$COMMAND" | grep -qE -- '\btalosctl\b.*\b(reset|wipe)\b'; then
    block 'talosctl reset/wipe is destructive and irreversible' 'Confirm explicitly with the user before proceeding'
fi

# rm-sensitive-path
if printf '%s' "$COMMAND" | grep -qE -- 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f.*(~|\$HOME|/home|/etc|/var|/usr|\.\s*$|\.\.\s*$)'; then
    block 'Recursive delete on a sensitive path' 'Confirm the exact path with the user before deleting'
fi

exit 0
