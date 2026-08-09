# Tooling & Critical Rules — Artemis-Cluster

Production GitOps homelab. Every push to `main` reconciles immediately to production via Flux.
**No staging cluster — test with `just kube apply-ks` before committing.**

This file is auto-loaded by every agent client (Claude Code via `CLAUDE.md`, opencode via
`opencode.json` → `instructions`). Anything both tools need goes here, not in a tool-specific file.

## Critical Rules

- **No SOPS** — secrets via 1Password ExternalSecret only (`ClusterSecretStore: onepassword-connect`)
- **No TZ env var** — k8tz handles timezone cluster-wide; never set `TZ` in pod specs
- **No shared OCIRepository** — every app gets its own standalone OCIRepository
- **No external hostnames for cluster traffic** — always `<app>.<namespace>.svc.cluster.local`
- **Routes in HelmRelease values** — `HTTPRoute` goes in helmrelease values, not standalone files
- **Test before commit** — `just kube apply-ks <ns> <ks>` then wait for explicit user confirmation
- **No `git add .` or `git add -A`** — stage specific files by name only
- **Never apply cluster changes through MCP** — no `kubectl apply`, no MCP apply equivalent

## just commands

```bash
just kube apply-ks <ns> <ks>              # apply a Kustomization live (always before commit)
just kube sync <ocirepo|hr|ks|es|gitrepo> # force-sync a Flux resource type
just kube render-local-ks <ns> <ks>       # validate with flate (offline, no cluster needed)
just kube snapshot                        # snapshot every kopiur SnapshotPolicy
just kube browse-pvc <ns> <pvc>           # browse a PVC interactively
just talos render-config <node>           # render Jinja2 node config
just talos apply-node <node>              # apply config live (no reboot)
```

Full recipe list: `bootstrap/mod.just`, `kubernetes/mod.just`.

## MCP servers

Three LiteLLM tiers plus memini. Registrations live in `.mcp.json` (Claude Code) and
`opencode.json` → `mcp` (opencode) — keep both in sync when a tier changes.

| Server            | Capability                                                                                |
| ----------------- | ----------------------------------------------------------------------------------------- |
| `litellm-ops`     | k8s (pods, logs, exec, resources, events, scale), Forgejo API, GitHub API, Home Assistant |
| `litellm-general` | Grafana, SearXNG web search + URL fetch, VictoriaLogs (LogsQL), Context7 docs             |
| `litellm-media`   | Sonarr / Radarr / Prowlarr, Jellyseerr                                                    |
| `memini`          | Cross-session semantic memory                                                             |

**Tool names are prefixed differently per client** — Claude Code renders them as
`mcp__<server>__<tool>`, opencode as `<server>_<tool>`. Never hardcode a full tool name from
this file; list the available tools and match on the server + tool portion.

- Web lookups go through the SearXNG tools, never a built-in web-search tool
- Default kubeconfig context is `artemis`. Switch to Frostlink: `kubectx frostlink`
- Prefer the k8s MCP tools over shelling out to `kubectl` for read-only inspection

## Skills and subagents

Catalog with natural-language triggers: `AGENTS.md` § Skills and § Agents. Not duplicated here
— that table drifted out of sync with `.agents/skills/` twice before, so `AGENTS.md` is the
only place it is listed.

Both clients discover skills from `.agents/skills/<name>/SKILL.md` — Claude Code through the
`.claude/skills/<name>` symlinks, opencode natively. Subagents in `.agents/agents/<name>.md` are
symlinked into `.claude/agents/` and `.opencode/agents/` for the same reason.
