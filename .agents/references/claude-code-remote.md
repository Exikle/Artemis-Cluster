# claude-code — Remote Control in the cluster

`clusters/artemis/kubernetes/apps/cortex/claude-code` runs `claude remote-control` in a pod. You can work on the
cluster from claude.ai/code or the Claude app without the workstation. Each session that you
start from there gets its own git worktree of a clone of this repo on the PVC of the pod.

## Access, and what guards it

| Reach      | How                                                                                                                                       |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Kubernetes | ServiceAccount bound to `cluster-admin`, as a kubeconfig with context `artemis`                                                           |
| Talos      | `talos.dev` ServiceAccount `claude-code-talos` (`os:admin`); Talos writes and rotates the Secret, mounted at `/var/run/secrets/talos.dev` |
| Forgejo    | `DUSK_BOT_CLUSTER_TOKEN` from the `forgejo` item; git and `fjo` act as dusk-bot                                                           |
| memini     | In-cluster service, same namespace settings as the workstation                                                                            |

The Talos access needs `cortex` in `allowedKubernetesNamespaces` of the `KubeTalosAPIAccessConfig`
in `clusters/artemis/talos/controlplane.yaml.j2`. Applying that change needs no reboot.

RBAC does not limit the access. These guards limit it:

- Permission mode `default`: every tool call outside the `.claude/settings.json` allowlist of the
  repo waits for approval in the app.
- `guard-destructive.sh` comes with the repo checkout. It blocks the destructive verbs as it does
  on the workstation.
- Branch protection on `main` allows pushes only from Exikle, so the pod lands work as a pull
  request. The `~/.claude/CLAUDE.md` of the pod (from `app/resources/CLAUDE.md`) says so.
- No ingress: the NetworkPolicy denies all of it. Remote Control only dials out.

## Tools

`app/resources/mise.toml` is the global mise configuration of the pod. It has the cluster tools
of the workstation plus the two MCP servers (`kubernetes-mcp-server`, `flux-operator-mcp`). The
`.mise/config.toml` of the repo adds its pins on top. The entrypoint puts `mise bin-paths` on
`PATH` and does not activate mise, because the mise env of the repo points `KUBECONFIG` and
`TALOSCONFIG` at files that exist only on the workstation.

The agentgateway tiers in the `.mcp.json` of the repo name a workstation-only `headersHelper`
path. The pod mounts its own `app/resources/ai-headers.mjs` at that same path. The helper reads
the tier keys (`KEY_OPS` / `KEY_GENERAL` from the `agentgateway` item) from files under
`/var/run/secrets/agentgateway` and returns `{"x-api-key": …}`. It uses files, not env vars.
Claude Code runs the helper without the environment of the pod, so an env-based helper returns no
headers. Then the 401 of the server sends Claude into OAuth discovery, which fails.
The entrypoint sets `enableAllProjectMcpServers`, so the tiers need no approval prompt.

There is no `op`, so 1Password-backed recipes stay on the workstation.

## The PVC is not backed up

`claude-code` holds the claude.ai login, plugins, tool installs and the clone. It has no kopiur
component, so the login credential never leaves the cluster. If the PVC is lost, you must repeat
the bootstrap.

## One-time bootstrap

Remote Control needs a full claude.ai login (a `claude setup-token` token is rejected). It also
needs a one-time interactive answer to "enable Remote Control" and to workspace trust. Until
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
making progress. In that case, exec in and run `claude auth login` again.

Remote Control refuses to start if `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or `DISABLE_GROWTHBOOK` is set. So none of them belong
in the env of the pod. Without a TTY, its status redraw once a second would flood the log.
`app/resources/log-filter.pl` strips the escapes and drops repeats.
