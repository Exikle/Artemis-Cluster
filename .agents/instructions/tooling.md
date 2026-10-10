# Tooling — Artemis-Cluster

Auto-loaded by every agent client (Claude Code via `CLAUDE.md`, opencode via `opencode.json` →
`instructions`). Anything both tools need goes here, not in a tool-specific file.

The rules that apply on every turn are in `AGENTS.md` § The rules that apply to every turn. They are not restated
here — that duplicate is what would drift.

## just

```bash
just kube suspend-ks <ns> <ks>          # suspend ONE ks — run for the root too, it does not bundle
just kube apply-ks <ns> <ks>            # render and apply a Kustomization live (suspends nothing)
just kube diff-ks <ns> <ks>             # read-only diff of a local render vs live; exit 1 = differs
just kube resume-ks <ns> <ks>           # resume ONE ks — root FIRST, then the target
just kube sync-flux <res> [name]        # force-sync hr|ks|gitrepo|ocirepo|es; NAME it, or it hits all
just kube render-ks <ns> <ks>           # validate with flate (offline, no cluster needed)
just kube snapshot-pvc [ns] [policy]    # snapshot one policy, a namespace, or all if no args
just kube browse-pvc <ns> <pvc>         # browse a PVC interactively
just kube check-postgres <ns> <app>     # verify an app's Postgres DSN + TLS actually work
just kube prune-pods                    # delete every pod not Running (incl. Pending)
just kube view-secret <ns> <secret>     # print a secret with every value decoded
just talos render-config <node>         # render Jinja2 node config
just talos apply-node <node>            # apply config live (no reboot)
just ai lint-agents                     # audit this repo's own agent config for drift
```

Full recipe list: `bootstrap/mod.just`, `kubernetes/mod.just`. Task runner modules live in
`bootstrap/`, `kubernetes/`, `talos/`, `terraform/`, `ansible/` and `ai/`, each a `mod.just`
wired from the root `.justfile`.

**Confirm-gated recipes need `just --yes`.** Every `talos` write verb — `apply-node`,
`reboot-node`, `reset-node`, `shutdown-node`, `upgrade-k8s`, `upgrade-node` — plus
`ansible apply` prompts `[y|N]` and aborts outright from a non-interactive shell
(`error: recipe was not confirmed`). Put `--yes` before the module name:
`just --yes talos apply-node <node>`. Do not pipe `printf 'y\n'` into it — the permission
classifier blocks that form.

## mise

Config is `.mise/config.toml` (**not** `.mise.toml`), with `.mise/mise.lock` checksummed. `talos`
is pinned to the cluster's running version. `just`, `kubectl`, `helmfile`, `op`, `gum`, `yq` and
`kustomize` are assumed globally installed.

`.mise/config.toml` also pins `LANG`/`LC_ALL` to `C.UTF-8` — ansible refuses to start otherwise,
because this box exports a locale it has not generated.

## Git hooks

`hk.pkl` is the single config for the pre-commit and commit-msg hooks and for `hk check` / `hk fix`
(no CI runs it here yet). Install once per clone with `hk install --mise` (worktrees share it).
`hk check --all` runs every check by hand and `hk fix --all` applies the formatters. Skip one step
with `HK_SKIP_STEPS=<name>`, never `--no-verify`. Commit subjects must parse as conventional
commits (`type(scope): subject`).

## MCP servers

Three LiteLLM tiers plus memini. **Tool names carry a server prefix that changes per client** —
Claude Code renders `mcp__<server>__<tool>`, opencode `<server>_<tool>`. Never hardcode a full
tool name from this file; list the tools and match on the server + tool portion.

| Server            | Capability                                                                                          |
| ----------------- | --------------------------------------------------------------------------------------------------- |
| `litellm-ops`     | k8s (pods, logs, exec, resources, events, scale), Flux (read-only), Forgejo, GitHub, Home Assistant |
| `litellm-general` | Grafana, SearXNG web search + URL fetch, VictoriaLogs (LogsQL), Context7 docs                       |
| `litellm-media`   | Sonarr / Radarr / Prowlarr, seerr (formerly Jellyseerr — the app and its tools are `seerr`)         |
| `memini`          | Cross-session semantic memory                                                                       |

- Prefer the k8s MCP tools over shelling out to `kubectl` for read-only inspection —
  pre-authenticated, structured, no shell quoting to get wrong.
- Web lookups go through the SearXNG tools, never a built-in web-search tool.
- Default kubeconfig context is `artemis`. Switch to Frostlink with `kubectx frostlink`.
- There are **five** MCP registration files across this machine and a tier change means editing
  all of them. `.agents/references/memory-config.md` § Five registration files is canonical.

## Subagents

How and when to delegate is in `~/.agents/AGENTS.md` § Delegation and context; Bash-call rules
are in `~/.agents/rules/bash-calls.md`. What is specific to Artemis:

- **Name the forbidden verbs in the brief.** "Follow the repo conventions" is not enough — say
  "do not commit, do not push, do not run `just kube apply-ks`" in those words.
- **`just kube apply-ks` applies the tree of the worktree you run it from** (`AGENTS.md` rule 7).
