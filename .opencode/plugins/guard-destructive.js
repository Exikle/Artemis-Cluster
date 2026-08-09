// opencode counterpart to .claude/hooks/guard-destructive.sh — blocks destructive cluster
// operations that bypass GitOps or the sanctioned just commands.
// Keep the rule list in sync with the Claude Code hook; both are documented in CLAUDE.md.

const RULES = [
  {
    pattern: /\bkubectl\b.*\bapply\b/,
    reason: "Direct kubectl apply bypasses GitOps",
    alternative: "Use 'just kube apply-ks <ns> <ks>' to apply changes via Flux",
  },
  {
    pattern:
      /\bkubectl delete\b.*\b(namespace|pvc|pv|persistentvolumeclaim|node|deployment|secret|helmrelease|kustomization|gateway|httproute|clusterrole)\b/,
    reason: "Deleting a critical Kubernetes resource",
    alternative: "Confirm with the user before deleting cluster resources",
  },
  {
    pattern: /\bhelm\b.*\b(install|upgrade|uninstall|delete|rollback)\b/,
    reason: "Direct helm mutations are not allowed — config lives in HelmRelease manifests",
    alternative: "Edit the HelmRelease values and apply via Flux",
  },
  {
    pattern: /\bflux\b.*\b(delete|uninstall)\b/,
    reason: "Destructive flux operation",
    alternative: "Confirm with the user before deleting Flux resources",
  },
  {
    pattern: /\btalosctl\b.*patch\s+machineconfig\b/,
    reason:
      "talosctl patch machineconfig duplicates array fields (machine.files etc.) and can brick the node",
    alternative:
      "Use 'just talos apply-node <node>' or talosctl apply-config --file for full config replacement",
  },
  {
    pattern: /\btalosctl\b.*\b(reset|wipe)\b/,
    reason: "talosctl reset/wipe is destructive and irreversible",
    alternative: "Confirm explicitly with the user before proceeding",
  },
  {
    pattern: /rm\s+-[a-zA-Z]*r[a-zA-Z]*f.*(~|\$HOME|\/home|\/etc|\/var|\/usr|\.\s*$|\.\.\s*$)/,
    reason: "Recursive delete on a sensitive path",
    alternative: "Confirm the exact path with the user before deleting",
  },
]

export const GuardDestructive = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return

      const command = output.args?.command ?? ""

      // Dry-run is always fine
      if (/--dry-run/.test(command)) return

      for (const rule of RULES) {
        if (rule.pattern.test(command)) {
          throw new Error(`BLOCKED: ${rule.reason}\nAlternative: ${rule.alternative}`)
        }
      }
    },
  }
}
