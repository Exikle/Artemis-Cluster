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

| Skill                        | Natural Language Triggers                                                                                                                               |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `deploy-app/SKILL.md`        | "deploy X", "add app X", "set up X in namespace Y", "create a new app", "onboard X to the cluster"                                                      |
| `fix-flux/SKILL.md`          | "flux is broken", "HelmRelease stuck", "kustomization not reconciling", "app won't deploy", "ExternalSecret not syncing", "something's wrong with flux" |
| `volsync-restore/SKILL.md`   | "restore X from backup", "recover PVC", "roll back X's data", "VolSync restore"                                                                         |
| `rbd-csi-recovery/SKILL.md`  | "pod stuck ContainerCreating", "RBD CSI", "volume won't mount", "CSI plugin broken", "input/output error on mount"                                      |
| `add-oidc-app/SKILL.md`      | "add SSO to X", "wire X into Pocket-ID", "set up OIDC for X", "add login to X", "single sign-on for X"                                                  |
| `add-agent-content/SKILL.md` | "add a new skill", "add an instruction", "update .agents/", "document this as a runbook"                                                                |
| `build-container/SKILL.md`   | "build a custom image for X", "no upstream image exists", "create a Dockerfile for X", "publish container to GHCR"                                      |
| `kubesearch/SKILL.md`        | "find examples for X", "how do others deploy X", "search kubesearch for X", "look up X in home-ops repos", "what's a good helmrelease for X"            |
| `review-app/SKILL.md`        | "review X deployment", "audit X manifests", "check X against conventions", "is X compliant", "lint X app", "what's wrong with X's manifests"            |

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
| `cortex`          | Open WebUI, Pipelines, agentmemory, SearXNG, ToolHive (8 MCP servers)                            |
| `home-automation` | Home Assistant, Frigate, Mosquitto, Zigbee2MQTT                                                  |
| `observability`   | kube-prometheus-stack, Grafana Operator, VictoriaLogs                                            |
| `security`        | Pocket-ID (OIDC provider)                                                                        |
| `rook-ceph`       | Block storage (3 OSDs on M710q nodes)                                                            |
| `network`         | Envoy Gateway, Cloudflare tunnel                                                                 |
