#!/usr/bin/env bash
# PreToolUse:Bash — blocks destructive cluster operations that bypass GitOps or sanctioned just commands
set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

block() {
    echo "BLOCKED: $1"
    echo "Alternative: $2"
    exit 2
}

# Dry-run is always fine
echo "$COMMAND" | grep -qE "\-\-dry-run" && exit 0

# Direct kubectl mutations — use `mise exec -- just kube apply-ks <ns> <ks>` instead
if echo "$COMMAND" | grep -qE "\bkubectl\b.*(apply|patch|scale|edit|replace|rollout restart)\b"; then
    block "Direct kubectl mutations bypass GitOps" "Use 'mise exec -- just kube apply-ks <ns> <ks>' to apply changes via Flux"
fi

# kubectl delete of critical resources — must be explicit
if echo "$COMMAND" | grep -qE "\bkubectl delete\b.*(namespace|pvc|pv|persistentvolumeclaim|node|deployment|secret|helmrelease|kustomization|gateway|httproute|clusterrole)\b"; then
    block "Deleting a critical Kubernetes resource" "Confirm with the user before deleting cluster resources"
fi

# Helm mutations — all config lives in HelmRelease manifests
if echo "$COMMAND" | grep -qE "\bhelm\b.*(install|upgrade|uninstall|delete|rollback)\b"; then
    block "Direct helm mutations are not allowed — config lives in HelmRelease manifests" "Edit the HelmRelease values and apply via Flux"
fi

# flux delete / uninstall
if echo "$COMMAND" | grep -qE "\bflux\b.*(delete|uninstall)\b"; then
    block "Destructive flux operation" "Confirm with the user before deleting Flux resources"
fi

# talosctl: block patch machineconfig (causes array duplication) and reset/wipe
if echo "$COMMAND" | grep -qE "\btalosctl\b.*patch\s+machineconfig\b"; then
    block "talosctl patch machineconfig duplicates array fields (machine.files etc.) and can brick the node" "Use 'mise exec -- just talos apply-node <node>' or talosctl apply-config --file for full config replacement"
fi
if echo "$COMMAND" | grep -qE "\btalosctl\b.*(reset|wipe)\b"; then
    block "talosctl reset/wipe is destructive and irreversible" "Confirm explicitly with the user before proceeding"
fi

# Recursive delete on dangerous paths
if echo "$COMMAND" | grep -qE "rm\s+-[a-zA-Z]*r[a-zA-Z]*f.*(~|\$HOME|/home|/etc|/var|/usr|\.\s*$|\.\.\s*$)"; then
    block "Recursive delete on a sensitive path" "Confirm the exact path with the user before deleting"
fi

exit 0
