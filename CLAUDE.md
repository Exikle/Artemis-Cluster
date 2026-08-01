# Artemis-Cluster — Claude Context

> **Cluster facts, hardware, namespaces, skills catalog, references index**: `AGENTS.md` — read it first, it is canonical.
> **Behavioral rules and runbooks**: `.agents/`

Production GitOps homelab. Every push to `main` reconciles immediately to production via Flux. **No staging cluster — test with `just kube apply-ks` before committing.**

---

## Tools Available This Session

### MCPs

| MCP                                     | Capability                                                  |
| --------------------------------------- | ----------------------------------------------------------- |
| `mcp__litellm-ops__k8s-*`               | kubectl — pods, logs, exec, resources, events, scale        |
| `mcp__litellm-ops__forgejo-*`           | Forgejo API — PRs, issues, files, repos, runners            |
| `mcp__litellm-ops__github-*`            | GitHub API — code search, file fetch, repo operations       |
| `mcp__litellm-ops__ha-*`                | Home Assistant — entities, services, automations, scripts   |
| `mcp__litellm-general__grafana-*`       | Grafana — dashboards, alerts, Loki logs, Prometheus metrics |
| `mcp__litellm-general__searxng-*`       | Web search + URL fetch (use instead of WebSearch)           |
| `mcp__litellm-general__victoria_logs-*` | VictoriaLogs — LogsQL queries, facets, streams              |
| `mcp__litellm-general__context7-*`      | Library/framework docs lookup                               |
| `mcp__litellm-media__arr-*`             | Sonarr, Radarr, Prowlarr — status, queue, search            |
| `mcp__litellm-media__seerr-*`           | Jellyseerr — media requests and approvals                   |
| `mcp__memini__*`                        | Cross-session semantic memory                               |

> Default kubeconfig context is `artemis`. Switch to Frostlink: `kubectx frostlink`
> Server registrations live in `.mcp.json` (repo root).

### just commands

```bash
just kube apply-ks <ns> <ks>              # apply a Kustomization live (always before commit)
just kube sync <ocirepo|hr|ks|es|gitrepo> # force-sync a Flux resource type
just kube render-local-ks <ns> <ks>       # validate with flate (offline, no cluster needed)
just kube snapshot                         # snapshot every kopiur SnapshotPolicy
just kube browse-pvc <ns> <pvc>           # browse a PVC interactively
just talos render-config <node>           # render Jinja2 node config
just talos apply-node <node>              # apply config live (no reboot)
```

### Skills

Full catalog and natural-language triggers: `AGENTS.md` § Skills. Not duplicated here — that table drifted out of sync with `.agents/skills/` twice before, so `AGENTS.md` is now the only place it's listed.

---

## Always-Loaded Instructions

@.agents/instructions/cluster-conventions.md
@.agents/instructions/yaml-conventions.md
@.agents/instructions/commit-style.md
@.agents/instructions/session.md

---

## Critical Rules

- **No SOPS** — secrets via 1Password ExternalSecret only (`ClusterSecretStore: onepassword-connect`)
- **No TZ env var** — k8tz handles timezone cluster-wide; never set `TZ` in pod specs
- **No shared OCIRepository** — every app gets its own standalone OCIRepository
- **No external hostnames for cluster traffic** — always `<app>.<namespace>.svc.cluster.local`
- **Routes in HelmRelease values** — `HTTPRoute` goes in helmrelease values, not standalone files
- **Test before commit** — `just kube apply-ks <ns> <ks>` then wait for explicit user confirmation
- **No `git add .` or `git add -A`** — stage specific files by name only
- **WebSearch removed** — use `mcp__litellm-general__searxng-*` for web lookups
