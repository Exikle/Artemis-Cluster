# Artemis-Cluster — Agent Context

GitOps homelab Kubernetes cluster running on Talos Linux, managed with Flux CD.

- **Domain**: `dcunha.io` | **Location**: Mississauga, Ontario (Eastern Time)
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecret (no SOPS)
- **Ingress**: Envoy Gateway (Gateway API / HTTPRoute) | **CNI**: Cilium
- **Repo**: https://github.com/Exikle/Artemis-Cluster

## Agent Instructions

Read `.agents/instructions/` before working in this repo:

| File                     | Contents                                                                    |
| ------------------------ | --------------------------------------------------------------------------- |
| `cluster-conventions.md` | GitOps patterns, Flux, app-template v5, VolSync, Rook-Ceph, Gateways, Talos |
| `yaml-conventions.md`    | Field ordering and YAML sorting rules for all manifests                     |
| `commit-style.md`        | Commit workflow, squash rules, message format, safety rules                 |
| `media-stack.md`         | Arr stack, cross-seed, download clients, Prowlarr rules                     |

## Skills

Use `.agents/skills/` for repeatable cluster tasks:

| Skill                        | Trigger phrase                                                         |
| ---------------------------- | ---------------------------------------------------------------------- |
| `deploy-app/SKILL.md`        | "deploy a new app", "add X to the cluster"                             |
| `fix-flux/SKILL.md`          | "flux is broken", "HelmRelease stuck", "kustomization not reconciling" |
| `volsync-restore/SKILL.md`   | "restore PVC", "roll back X from backup"                               |
| `rbd-csi-recovery/SKILL.md`  | "pod stuck ContainerCreating", "RBD CSI", "volume attachment error"    |
| `add-oidc-app/SKILL.md`      | "add SSO to X", "wire up Pocket-ID", "set up OIDC for X"               |
| `add-agent-content/SKILL.md` | "add a new skill", "add a new instruction", "update .agents/"          |

## Repo Structure

```
kubernetes/
  apps/           # App HelmReleases organized by namespace
  components/     # Shared kustomize components (volsync, etc.)
  flux/sync/      # Entrypoint: single Kustomization → kubernetes/apps
talos/            # Node configs (controlplane.yaml, worker.yaml)
bootstrap/        # Bootstrap justfile and secrets injection
.agents/          # AI agent instructions and skills (this directory)
```

## Key Namespaces

| Namespace         | Key Apps                                                                                         |
| ----------------- | ------------------------------------------------------------------------------------------------ |
| `media`           | Sonarr ×3, Radarr, Jellyfin, Jellyseerr, SABnzbd, qBittorrent+Gluetun, Prowlarr, autobrr, Bazarr |
| `cortex`          | Open WebUI, Pipelines, mem0, Qdrant, SearXNG, ToolHive                                           |
| `home-automation` | Home Assistant, Frigate, Mosquitto, Zigbee2MQTT                                                  |
| `observability`   | VictoriaMetrics stack, Grafana Operator, VictoriaLogs                                            |
| `security`        | Kanidm (OIDC provider)                                                                           |
| `rook-ceph`       | Block storage (3 OSDs on M710q nodes)                                                            |
| `network`         | Envoy Gateway, Cloudflare tunnel                                                                 |
