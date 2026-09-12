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
[[ "$INPUT" =~ (kubectl|helm|flux|talosctl|just|(^|[^[:alnum:]_])rm[^[:alnum:]_]|(^|[^[:alnum:]_])mv[^[:alnum:]_]|(^|[^[:alnum:]_])git[^[:alnum:]_]) ]] || exit 0

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

AGENT_ID=$(printf '%s' "$INPUT" | python3 -c 'import sys, json
try:
    print(json.load(sys.stdin).get("agent_id") or "")
except Exception:
    print("")' 2>/dev/null || echo "")

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

# just-cluster-mutation-subagent — fires only inside a subagent; the main thread is never blocked
if [ -n "$AGENT_ID" ] && printf '%s' "$COMMAND" | grep -qE -- '\bjust\b.*\b(kube\s+(apply|delete|suspend|resume)-ks|talos\s+apply-node)\b'; then
    block 'A subagent may not mutate the live cluster — these commands are the human'"'"'s to run. The safety of '"'"'just kube apply-ks'"'"' is not in the recipe, it is in the procedure around it: suspend root + target first, watch the result, wait for confirmation, resume in order after CI is green. A subagent skips all four.' 'Write the manifests and validate them offline ('"'"'just kube render-ks <ns> <ks>'"'"' needs no cluster), or read live state with '"'"'just kube diff-ks <ns> <ks>'"'"'. Report the change and let the human apply it.'
fi

# git-write-subagent — fires only inside a subagent; the main thread is never blocked
if [ -n "$AGENT_ID" ] && printf '%s' "$COMMAND" | grep -qE -- '\bgit\b(\s+-\S+|\s+-C\s+\S+)*\s+(add|commit|push|rebase|merge)\b'; then
    block 'A subagent may not write to git history — staging, committing, pushing, rebasing and merging are the human'"'"'s. Agent definitions that promise '"'"'never writes'"'"' are frontmatter, which is cached at session start and cannot be relied on; this rule is a PreToolUse hook, so it holds under every permission mode including --dangerously-skip-permissions.' 'Leave the working tree dirty and report what you changed. The human stages by name, runs '"'"'git diff --staged'"'"', and commits. Read-only git (status, log, diff, show, worktree) is unaffected.'
fi

# kubectl-apply
if printf '%s' "$COMMAND" | grep -qE -- '\bkubectl\b.*\bapply\b'; then
    block 'Direct kubectl apply bypasses GitOps' 'Use '"'"'just kube apply-ks <ns> <ks>'"'"' to apply changes via Flux'
fi

# kubectl-delete-critical
if printf '%s' "$COMMAND" | grep -qE -- '\bkubectl\b.*\bdelete\b.*\b(namespace|pvc|pv|persistentvolumeclaim|node|deployment|secret|helmrelease|kustomization|gateway|httproute|clusterrole)\b'; then
    # exempt: PVC recreation (miroir StorageClass migrations, restore drills) is routine and always paired with a verified kopiur snapshot. The marker opts a single command out of THIS rule only -- every other rule, including talosctl reset/wipe, still applies. See .agents/skills/recreate-pvc/SKILL.md.
    if ! printf '%s' "$COMMAND" | grep -qE -- I_HAVE_A_KOPIUR_SNAPSHOT; then
        block 'Deleting a critical Kubernetes resource' 'Confirm with the user before deleting cluster resources. If this is a planned PVC recreation with a verified snapshot, append the marker documented in .agents/skills/recreate-pvc/SKILL.md'
    fi
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

# mv-over-managed-dotfile
if printf '%s' "$COMMAND" | grep -qE -- '\bmv\b\s+[^|;&]*\s+(~|\$HOME|/home/[a-z]+)/\.(claude|config|local)/'; then
    block 'mv REPLACES a mise-managed symlink with a regular file, silently unlinking it from ~/dotfiles — edits then stop reaching the repo' 'Use `cp` instead of `mv`, which writes through the symlink and keeps it intact'
fi

exit 0
