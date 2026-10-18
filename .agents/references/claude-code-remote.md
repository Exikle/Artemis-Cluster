# claude-code — Remote Control in the cluster

`kubernetes/apps/cortex/claude-code` runs `claude remote-control` in a pod, so the cluster can be
worked on from claude.ai/code or the Claude app without the workstation. Each session started
from there gets its own git worktree of a clone of this repo on the pod's PVC.

## Access, and what guards it

| Reach      | How                                                                                                                                       |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Kubernetes | ServiceAccount bound to `cluster-admin`, as a kubeconfig with context `artemis`                                                           |
| Talos      | `talos.dev` ServiceAccount `claude-code-talos` (`os:admin`); Talos writes and rotates the Secret, mounted at `/var/run/secrets/talos.dev` |
| Forgejo    | `DUSK_BOT_CLUSTER_TOKEN` from the `forgejo` item; git and `fjo` act as dusk-bot                                                           |
| memini     | In-cluster service, same namespace settings as the workstation                                                                            |

The Talos access needs `cortex` in `allowedKubernetesNamespaces` of the `KubeTalosAPIAccessConfig`
in `talos/controlplane.yaml.j2`. Applying that change needs no reboot.

RBAC does not limit it. The guards are:

- **Permission mode `default`**: every tool call outside the repo's `.claude/settings.json`
  allowlist waits for approval in the app.
- **`guard-destructive.sh`** comes with the repo checkout and blocks the destructive verbs as it
  does on the workstation.
- **Branch protection on `main`** allows pushes only from Exikle, so the pod lands work as a
  pull request. Its `~/.claude/CLAUDE.md` (from `app/resources/CLAUDE.md`) says so.
- **No ingress**: the NetworkPolicy denies all of it. Remote Control only dials out.

## Tools

`app/resources/mise.toml` is the pod's global mise config: the workstation's cluster tools plus
the two MCP servers (`kubernetes-mcp-server`, `flux-operator-mcp`). The repo's own
`.mise/config.toml` adds its pins on top. The entrypoint puts `mise bin-paths` on `PATH` rather
than activating mise, because the repo's mise env points `KUBECONFIG` and `TALOSCONFIG` at
files that exist only on the workstation.

The repo's `.mcp.json` LiteLLM tiers do not work in the pod: their `headersHelper` is a
workstation path. There is no `op`, so 1Password-backed recipes stay on the workstation.

## The PVC is not backed up

`claude-code` holds the claude.ai login, plugins, tool installs and the clone. It has no kopiur
component, so the login credential never leaves the cluster. Losing it means repeating the
bootstrap.

## One-time bootstrap

Remote Control needs a full claude.ai login (a `claude setup-token` token is rejected) and a
one-time interactive "enable Remote Control" and workspace-trust answer. Until
`~/.remote-control-ready` exists, the pod installs everything and then sleeps.

```bash
kubectl exec -it -n cortex deploy/claude-code -- bash
export PATH="$HOME/.local/bin:$PATH"
claude auth login                                # claude.ai account, paste the code back
cd ~/Artemis-Cluster && claude remote-control    # answer y and y, then Ctrl-C
touch ~/.remote-control-ready
exit
kubectl rollout restart -n cortex deploy/claude-code
```

The server then shows up as `artemis` in claude.ai/code. If the login expires, sessions stop
making progress: exec in and run `claude auth login` again.

Remote Control refuses to start with `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or `DISABLE_GROWTHBOOK` set, so none of them belong in
the pod's env. Without a TTY its once-a-second status redraw would flood the log;
`app/resources/log-filter.pl` strips the escapes and drops repeats.
