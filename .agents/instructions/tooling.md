# Tooling — Artemis-Cluster

Every agent client loads this file automatically (Claude Code via `CLAUDE.md`, opencode via
`opencode.json` → `instructions`). Anything that both tools need goes here, not in a
tool-specific file.

The rules that apply on every turn are in `AGENTS.md` § The rules that apply to every turn. This
file does not restate them. That duplicate would drift.

## just

```bash
just kube suspend-ks <ns> <ks>          # suspend ONE ks — run for the root too, it does not bundle
just kube apply-ks <ns> <ks>            # render and apply a Kustomization live (suspends nothing)
just kube diff-ks <ns> <ks>             # read-only diff of a local render vs live; exit 1 = differs
just kube resume-ks <ns> <ks>           # resume ONE ks — root FIRST, then the target
just kube sync-flux <res> [name]        # force-sync hr|ks|gitrepo|ocirepo|es; NAME it, or it hits all
just kube render-ks <ns> <ks>           # validate with flate (offline; [private], runs by name but not in --list); the root uses flux build against the live cluster
just kube snapshot-pvc [ns] [policy]    # snapshot one policy, a namespace, or all if no args
just kube browse-pvc <ns> <pvc>         # browse a PVC interactively
just kube check-postgres <ns> <app>     # verify an app's Postgres DSN + TLS actually work
just kube prune-pods                    # delete every pod not Running (incl. Pending)
just kube view-secret <ns> <secret>     # print a secret with every value decoded
just talos render-config <node>         # render Jinja2 node config
just talos apply-node <node>            # apply config live (no reboot)
just ai lint-agents                     # audit this repo's own agent config for drift
just wt new <type>/<slug>              # create a worktree + branch from main (AGENTS.md rule 7)
just wt rm <type>/<slug>               # remove it; refuses unless the branch is an ancestor of main
just wt ls                             # list worktrees
```

For the full recipe list, run `just --list <module>`, or read `*/mod.just` and
`scripts/worktree.just`. The task runner modules live in `bootstrap/`, `kubernetes/`, `talos/`,
`terraform/`, `ansible/` and `ai/`. Each is a `mod.just` wired from the root `.justfile`.

Confirm-gated recipes need `just --yes`. Every `talos` write verb (`apply-node`, `reboot-node`,
`reset-node`, `shutdown-node`, `upgrade-k8s`, `upgrade-node`) and `ansible apply` prompt
`[y|N]`. From a non-interactive shell, they abort outright (`error: recipe was not confirmed`).
Put `--yes` before the module name: `just --yes talos apply-node <node>`. Do not pipe
`printf 'y\n'` into it. The permission classifier blocks that form.

## mise

The configuration file is `.mise/config.toml` (not `.mise.toml`). There is deliberately no
`mise.lock`. `lockfile = false` is set there and globally, every tool is an exact pin that
Renovate bumps, and mise verifies signatures at install. Tools shared with other repos (hk, uv,
python, flate, oxfmt and the rest) come from `include` lines that point at `base.toml` and
`cluster.toml` in <https://git.dcunha.io/exikle/mise-config>, pinned by commit. Edit them there,
not here. `talos` is pinned locally to the running version of the cluster. The repo assumes that
`just`, `kubectl`, `helmfile`, `op`, `gum` and `kustomize` are installed globally.

`.mise/config.toml` also pins `LANG` and `LC_ALL` to `C.UTF-8`. Otherwise ansible refuses to
start, because this box exports a locale that it did not generate.

## Git hooks

`hk.pkl` is the single configuration for the pre-commit and commit-msg hooks and for `hk check` /
`hk fix` (no CI runs it here yet). Install once per clone with `hk install --mise` (worktrees
share it). `hk check --all` runs every check by hand. `hk fix --all` applies the formatters. To
skip one step, use `HK_SKIP_STEPS=<name>`, never `--no-verify`. Commit subjects must parse as
conventional commits (`type(scope): subject`).

## MCP servers

There are two agentgateway tiers plus memini. Tool names carry a server prefix that changes per
client. Claude Code renders `mcp__<server>__<tool>`. opencode renders `<server>_<tool>`. Never
hardcode a full tool name from this file. List the tools and match on the server and tool
portion. Within a server, tools are `<target>_<tool>` (for example `victoria-logs_query`).

| Server       | Capability                                                                                                                                                                               |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ai-ops`     | k8s (pods, logs, exec, resources, events, scale), Flux (read-only), Forgejo, GitHub, Home Assistant                                                                                      |
| `ai-general` | Grafana, SearXNG web search + URL fetch, VictoriaLogs (LogsQL), Context7 docs, SparkyFitness, Sonarr / Radarr / Prowlarr, seerr (formerly Jellyseerr). The app and its tools are `seerr` |
| `memini`     | Cross-session semantic memory                                                                                                                                                            |

- For read-only inspection, use the k8s MCP tools, not `kubectl`. They are pre-authenticated and
  structured, and they have no shell quoting to get wrong.
- Web lookups go through the SearXNG tools, never a built-in web-search tool.
- The default kubeconfig context is `artemis`. Switch to Frostlink with `kubectx frostlink`.
- There are six MCP registration files across this machine. A tier change means that you edit
  all of them. `.agents/references/memory-config.md` § Six registration files is canonical.

## Subagents

How and when to delegate is in `~/.agents/AGENTS.md` § Delegation and context. The Bash-call
rules are in `~/.agents/rules/bash-calls.md`. These rules are specific to Artemis:

- Name the forbidden verbs in the brief. "Follow the repo conventions" is not enough. Write
  "do not commit, do not push, do not run `just kube apply-ks`" in those words.
- `just kube apply-ks` applies the tree of the worktree that you run it from (`AGENTS.md` rule 7).
