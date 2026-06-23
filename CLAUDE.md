# Artemis-Cluster — Claude Context

> **Full hardware/networking reference**: `AGENTS.md`
> **Behavioral rules and runbooks**: `.agents/`

## What Is This

Production GitOps homelab — 6 Talos nodes (3 Lenovo M710q control planes + 3 Proxmox worker VMs), Rook-Ceph for app storage, ~41TB TrueNAS NFS for media. Every push to `main` reconciles immediately to production via Flux. **No staging cluster — test with `just kube apply-ks` before committing.**

## Cluster Map

| Namespace          | Key Apps                                                                                                 |
| ------------------ | -------------------------------------------------------------------------------------------------------- |
| `flux-system`      | flux-operator, flux-instance, flux-monitor, notifications                                                |
| `media`            | Sonarr, Radarr, Jellyfin, Jellyseerr, SABnzbd, qBittorrent+Gluetun, Prowlarr, autobrr, Bazarr            |
| `cortex`           | Open WebUI, Pipelines, memini, SearXNG, text-embeddings-inference, ToolHive (3 gateways + 9 MCP servers) |
| `home-automation`  | Home Assistant, Frigate, Mosquitto, Zigbee2MQTT, Matter Server                                           |
| `observability`    | kube-prometheus-stack, Grafana Operator, VictoriaLogs                                                    |
| `security`         | Pocket-ID (OIDC provider at `auth.dcunha.io`)                                                            |
| `network`          | Envoy Gateway (internal + external), Cloudflare tunnel, external-dns-unifi                               |
| `external-secrets` | External Secrets Operator + 1Password Connect                                                            |
| `rook-ceph`        | 3-OSD Ceph cluster — `ceph-block` (RWO) + `ceph-filesystem` (RWX)                                        |

## Tools Available This Session

### MCPs

| MCP                                   | Capability                                                  |
| ------------------------------------- | ----------------------------------------------------------- |
| `mcp__artemis-ops__mcp-k8s_*`         | kubectl — pods, logs, exec, resources, events, scale        |
| `mcp__artemis-ops__mcp-forgejo_*`     | Forgejo API — PRs, issues, files, repos, runners            |
| `mcp__artemis-ops__mcp-github_*`      | GitHub API — code search, file fetch, repo operations       |
| `mcp__artemis-ops__mcp-ha_*`          | Home Assistant — entities, services, automations, scripts   |
| `mcp__artemis-general__mcp-grafana_*` | Grafana — dashboards, alerts, Loki logs, Prometheus metrics |
| `mcp__artemis-general__mcp-searxng_*` | Web search + URL fetch (use instead of WebSearch)           |
| `mcp__artemis-media__mcp-arr_*`       | Sonarr, Radarr, Prowlarr — status, queue, search            |
| `mcp__artemis-media__mcp-seerr_*`     | Jellyseerr — media requests and approvals                   |
| `mcp__memini__*`                      | Cross-session semantic memory                               |

> Default kubeconfig context is `artemis`. Switch to Frostlink: `kubectx frostlink`

### just commands

```bash
just kube apply-ks <ns> <ks>              # apply a Kustomization live (always before commit)
just kube sync <ocirepo|hr|ks|es|gitrepo> # force-sync a Flux resource type
just kube render-local-ks <ns> <ks>       # validate with flate (offline, no cluster needed)
just kube snapshot                         # trigger VolSync manual snapshots
just kube browse-pvc <ns> <pvc>           # browse a PVC interactively
just talos render-config <node>           # render Jinja2 node config
just talos apply-node <node>              # apply config live (no reboot)
```

### Skills — invoke by natural language

| Say this...                                                    | Skill               |
| -------------------------------------------------------------- | ------------------- |
| "deploy X", "add app X", "set up X in namespace Y"             | `deploy-app`        |
| "flux is broken", "HelmRelease stuck", "kustomization failing" | `fix-flux`          |
| "restore X from backup", "recover PVC", "VolSync restore"      | `volsync-restore`   |
| "pod stuck ContainerCreating", "RBD CSI", "won't mount"        | `rbd-csi-recovery`  |
| "add SSO to X", "wire X into Pocket-ID", "OIDC for X"          | `add-oidc-app`      |
| "find examples for X", "how do others deploy X"                | `kubesearch`        |
| "review X deployment", "audit X manifests"                     | `review-app`        |
| "create Forgejo repo", "set action secret", "check runner"     | `forgejo`           |
| "cluster status", "what's broken", "health check"              | `cluster-status`    |
| "watch the deploy", "monitor rollout", "loop watch"            | `watch-deploys`     |
| "triage renovate PRs", "which updates are safe to merge"       | `triage-renovate`   |
| "add a new skill", "document this as a runbook"                | `add-agent-content` |
| "add PostgreSQL", "CNPG cluster", "deploy database"            | `cnpg-database`     |
| "apply talos config", "upgrade talos node", "extension change" | `talos-ops`         |
| "add a Grafana dashboard", "GrafanaDashboard CRD"              | `grafana-dashboard` |
| "validate manifests", "flate diff", "pre-commit check"         | `flux-validate`     |
| "backup health check", "are backups working", "restore drill"  | `restore-drill`     |
| "build a custom image", "no upstream image"                    | `build-container`   |
| "move X to namespace Y", "migrate X from default"              | `migrate-namespace` |
| "automate browser", "playwright", "inspect UI network calls"   | `playwright`        |

---

## Always-Loaded Instructions

@.agents/instructions/cluster-conventions.md
@.agents/instructions/yaml-conventions.md
@.agents/instructions/commit-style.md

---

## Topic References (load on demand)

| File                          | Contents                                                      |
| ----------------------------- | ------------------------------------------------------------- |
| `references/flux-patterns.md` | Flux reconciliation, cross-namespace gotchas, CRD timing race |
| `references/storage.md`       | Rook-Ceph, VolSync, NFS, RBD CSI recovery                     |
| `references/networking.md`    | Gateways, cluster traffic rules, VLANs, Multus IoT            |
| `references/observability.md` | Grafana Operator, ServiceMonitor gaps, Rook metrics, kromgo   |
| `references/talos.md`         | Node config management, extension changes, tuppr              |
| `instructions/media-stack.md` | Arr stack, cross-seed, download clients, Prowlarr rules       |

---

## Critical Rules

- **No SOPS** — secrets via 1Password ExternalSecret only (`ClusterSecretStore: onepassword-connect`)
- **No TZ env var** — k8tz handles timezone cluster-wide; never set `TZ` in pod specs
- **No shared OCIRepository** — every app gets its own standalone OCIRepository
- **No external hostnames for cluster traffic** — always `<app>.<namespace>.svc.cluster.local`
- **Routes in HelmRelease values** — `HTTPRoute` goes in helmrelease values, not standalone files
- **Test before commit** — `just kube apply-ks <ns> <ks>` then wait for explicit user confirmation
- **No `git add .` or `git add -A`** — stage specific files by name only
- **WebSearch removed** — use `mcp__artemis-general__mcp-searxng_*` for web lookups
