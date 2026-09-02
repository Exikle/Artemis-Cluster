// GENERATED FILE — do not edit here.
// Source:     .claude/hooks/guard-rules.json  (canonical: dotfiles/home/claude/agent-hooks/)
// Regenerate: python3 .claude/hooks/gen-guards.py
// Verified:   python3 .claude/hooks/gen-guards.py --check   (runs in pre-commit)
//
// opencode counterpart to .claude/hooks/guard-destructive.sh. Both are generated from
// the same rule table, so the two cannot drift apart.

const RULES = [
  {
    id: "kubectl-apply",
    pattern: new RegExp("\\bkubectl\\b.*\\bapply\\b"),
    reason: "Direct kubectl apply bypasses GitOps",
    alternative: "Use 'just kube apply-ks <ns> <ks>' to apply changes via Flux",
  },
  {
    id: "kubectl-delete-critical",
    pattern: new RegExp("\\bkubectl\\b.*\\bdelete\\b.*\\b(namespace|pvc|pv|persistentvolumeclaim|node|deployment|secret|helmrelease|kustomization|gateway|httproute|clusterrole)\\b"),
    reason: "Deleting a critical Kubernetes resource",
    alternative: "Confirm with the user before deleting cluster resources",
  },
  {
    id: "helm-mutation",
    pattern: new RegExp("\\bhelm\\b.*\\b(install|upgrade|uninstall|delete|rollback)\\b"),
    reason: "Direct helm mutations are not allowed \u2014 config lives in HelmRelease manifests",
    alternative: "Edit the HelmRelease values and apply via Flux",
  },
  {
    id: "flux-destructive",
    pattern: new RegExp("\\bflux\\b.*\\b(delete|uninstall)\\b"),
    reason: "Destructive flux operation",
    alternative: "Confirm with the user before deleting Flux resources",
  },
  {
    id: "talosctl-patch-machineconfig",
    pattern: new RegExp("\\btalosctl\\b.*patch\\s+machineconfig\\b"),
    reason: "talosctl patch machineconfig duplicates array fields (machine.files etc.) and can brick the node",
    alternative: "Use 'just talos apply-node <node>' or talosctl apply-config --file for full config replacement",
  },
  {
    id: "talosctl-reset",
    pattern: new RegExp("\\btalosctl\\b.*\\b(reset|wipe)\\b"),
    reason: "talosctl reset/wipe is destructive and irreversible",
    alternative: "Confirm explicitly with the user before proceeding",
  },
  {
    id: "rm-sensitive-path",
    pattern: new RegExp("rm\\s+-[a-zA-Z]*r[a-zA-Z]*f.*(~|\\$HOME|/home|/etc|/var|/usr|\\.\\s*$|\\.\\.\\s*$)"),
    reason: "Recursive delete on a sensitive path",
    alternative: "Confirm the exact path with the user before deleting",
  },
]

const ALWAYS_ALLOW = new RegExp("--dry-run")

// Strip heredoc BODIES before any rule sees the command. A heredoc body is data being
// written to a file, not a command being executed, so matching rules against it produced
// false positives. The heredoc's opening line is kept, so the real command on it is still
// checked. <<WORD / <<'WORD' / <<"WORD" / <<-WORD, but not the <<<herestring form.
const HEREDOC_START = /<<-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/g

function stripHeredocBodies(command) {
  const lines = command.split("\n")
  const kept = []
  let i = 0
  while (i < lines.length) {
    const line = lines[i]
    kept.push(line)
    i += 1
    HEREDOC_START.lastIndex = 0
    for (const m of line.matchAll(HEREDOC_START)) {
      const delim = m[2]
      while (i < lines.length && lines[i].trim() !== delim) i += 1
      if (i < lines.length) i += 1 // consume the terminator line itself
    }
  }
  return kept.join("\n")
}

export const GuardDestructive = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return

      const command = stripHeredocBodies(output.args?.command ?? "")

      if (ALWAYS_ALLOW.test(command)) return

      for (const rule of RULES) {
        if (rule.pattern.test(command)) {
          throw new Error(`BLOCKED: ${rule.reason}\nAlternative: ${rule.alternative}`)
        }
      }
    },
  }
}
