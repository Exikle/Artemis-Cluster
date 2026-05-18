# Artemis-Cluster — Agent Context

GitOps homelab Kubernetes cluster on Talos Linux, managed with Flux CD.
This file is the canonical reference for all AI agents working in this repo.

- **User**: exikle (Dixon) — Mississauga ON (Eastern Time)
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecret (no SOPS)
- **Domain**: `dcunha.io` | **Repo**: <https://github.com/Exikle/Artemis-Cluster>
- **CNI**: Cilium (BGP) | **Ingress**: Envoy Gateway (Gateway API / HTTPRoute)

---

## Repo Structure

```text
.agents/          # AI agent instructions, references, and skills
bootstrap/        # Bootstrap justfile — run order matters
talos/            # Node configs (render-config from .yaml.j2 templates)
kubernetes/
  apps/           # App HelmReleases by namespace
  components/     # Shared kustomize components (volsync, etc.)
  flux/sync/      # Entrypoint Kustomization → kubernetes/apps
```

---

## Hardware

### Control Planes (Metal)

- **3× Lenovo M710q** — `talos-cp-01/02/03`
    - Boot: 256GB SATA SSD | Ceph OSD: 256GB NVMe | VLAN 1099 (LAB, static IPs)

### Workers (Proxmox VMs on `pantheon`)

- **talos-w-01, talos-w-02**: 32GB RAM, 6 vCPU (NUMA), 64GB disk
- **talos-gpu-01**: 32GB RAM, 6 vCPU, ASRock Arc A380 passthrough (6GB)

### Proxmox Host (`pantheon`)

- HPE ML150 G9 | 2× Xeon E5-2620 v3 (24 cores total)
- HP RAID card must be in HBA mode (ssacli or F9 BIOS) to expose raw disks

### Storage

- **TrueNAS** (`atlas`, 10.10.99.100): ~41TB usable (3× RAIDZ2), NFS `/mnt/atlas/media`
- **Rook-Ceph**: 3 OSDs (one per M710q, 256GB SATA each) — app config/DBs only, not media

---

## Networking

| VLAN | Name | Subnet          | Purpose                          |
| ---- | ---- | --------------- | -------------------------------- |
| 1001 | HME  | 10.10.1.0/24    | Trusted home                     |
| 1099 | LAB  | 10.10.99.0/24   | Servers, K8s nodes               |
| 1152 | IOT  | 10.10.152.0/24  | IoT (reachable from worker pods) |
| 1151 | GST  | 10.10.151.0/24  | Guest                            |
| 1088 | TST  | 192.168.88.0/24 | Testing                          |

- **UCG-Max** (10.10.99.1): WAN/NAT, VLANs, DHCP, BGP AS 64533, DNS (dcunha.io via external-dns-unifi)
- **Mikrotik CRS309**: L2 switch only

---

## Namespaces & Apps

| Namespace          | Key Apps                                                                                         |
| ------------------ | ------------------------------------------------------------------------------------------------ |
| `flux-system`      | flux-operator, flux-instance, flux-monitor, notifications                                        |
| `media`            | Sonarr ×3, Radarr, Jellyfin, Jellyseerr, SABnzbd, qBittorrent+Gluetun, Prowlarr, autobrr, Bazarr |
| `cortex`           | Open WebUI, Pipelines, mem0, Qdrant, SearXNG, ToolHive (3 gateways + 8 MCP servers)              |
| `home-automation`  | Home Assistant, Frigate, Mosquitto, Zigbee2MQTT, Matter Server                                   |
| `observability`    | kube-prometheus-stack, Grafana Operator, VictoriaLogs                                            |
| `security`         | Pocket-ID (OIDC provider)                                                                        |
| `rook-ceph`        | Rook-Ceph cluster (3 OSDs)                                                                       |
| `network`          | Envoy Gateway, Cloudflare tunnel                                                                 |
| `external-secrets` | External Secrets Operator (1Password)                                                            |

---

## Bootstrap Order

1. `talosctl apply-config --insecure --nodes <cp-ip> --file talos/controlplane.yaml`
2. `talosctl apply-config --insecure --nodes <worker-ip> --file talos/worker.yaml`
3. `just bootstrap` — Cilium → CoreDNS → cert-manager → external-secrets → 1Password → flux-operator → flux-instance

---

## Dev Tooling (mise)

```toml
talhelper = "latest"
helm = "4.1.4"
k9s = "latest"
gh = "latest"
node = "latest"
prettier = "latest"
"github:mitsuhiko/minijinja" = "latest"
```

Task runner: `just` (`bootstrap/mod.just`, `kubernetes/mod.just`)

---

## Known Hardware & Ops Issues

- **Proxmox HP RAID**: ssacli or F9 BIOS → HBA mode to expose raw disks
- **Eaton UPS**: batteries dead — not providing real protection
- **TrueNAS netdata.conf**: must be replaced after every TrueNAS update — run on `atlas` (10.10.99.100):

```bash
curl -s https://raw.githubusercontent.com/Supporterino/truenas-graphite-to-prometheus/main/netdata.conf \
  | sudo tee /etc/netdata/netdata.conf && sudo systemctl restart netdata
```

---

## Agent Instructions

Read `.agents/instructions/` before working in this repo:

| File                     | Contents                                                         |
| ------------------------ | ---------------------------------------------------------------- |
| `cluster-conventions.md` | App structure, app-template v5, secrets pattern, reference index |
| `yaml-conventions.md`    | Field ordering and YAML sorting rules for all manifests          |
| `commit-style.md`        | Commit workflow, squash rules, message format, safety rules      |
| `media-stack.md`         | Arr stack, cross-seed, download clients, Prowlarr rules          |

Read `.agents/references/` for topic-specific patterns (load only what's relevant):

| File               | Contents                                                                     |
| ------------------ | ---------------------------------------------------------------------------- |
| `flux-patterns.md` | Flux reconciliation, cross-namespace gotchas, CRD timing race, anti-patterns |
| `storage.md`       | Rook-Ceph, VolSync, NFS, RBD CSI recovery, Prometheus WAL                    |
| `networking.md`    | Gateways (internal/external), cluster traffic rules, VLANs                   |
| `observability.md` | Grafana Operator, ServiceMonitor gaps, Rook metrics, kromgo badges           |
| `talos.md`         | Node config management, extension changes, automated upgrades                |

---

## Skills

Use `.agents/skills/` for repeatable cluster tasks:

| Skill                        | Natural Language Triggers                                                                                 |
| ---------------------------- | --------------------------------------------------------------------------------------------------------- |
| `deploy-app/SKILL.md`        | "deploy X", "add app X", "set up X in namespace Y", "create a new app", "onboard X to the cluster"        |
| `fix-flux/SKILL.md`          | "flux is broken", "HelmRelease stuck", "kustomization not reconciling", "ExternalSecret not syncing"      |
| `volsync-restore/SKILL.md`   | "restore X from backup", "recover PVC", "roll back X's data", "VolSync restore"                           |
| `rbd-csi-recovery/SKILL.md`  | "pod stuck ContainerCreating", "RBD CSI", "volume won't mount", "input/output error on mount"             |
| `add-oidc-app/SKILL.md`      | "add SSO to X", "wire X into Pocket-ID", "set up OIDC for X", "single sign-on for X"                      |
| `add-agent-content/SKILL.md` | "add a new skill", "add an instruction", "update .agents/", "document this as a runbook"                  |
| `build-container/SKILL.md`   | "build a custom image for X", "no upstream image exists", "create a Dockerfile for X"                     |
| `kubesearch/SKILL.md`        | "find examples for X", "how do others deploy X", "search kubesearch for X", "look up X in home-ops repos" |
| `review-app/SKILL.md`        | "review X deployment", "audit X manifests", "check X against conventions", "lint X app"                   |
