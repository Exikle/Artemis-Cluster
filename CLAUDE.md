# Artemis-Cluster — Claude Context

> **Behavioral rules, YAML conventions, commit workflow, and task runbooks are in `.agents/`.**
> Read `.agents/instructions/` before touching manifests or making commits.

## Identity

- **User**: exikle (Dixon) — Jellyfin admin, Mississauga ON (Eastern Time)
- **Cluster**: Artemis-Cluster on Talos Linux
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecret (no SOPS)
- **Domain**: `dcunha.io` | **Repo**: <https://github.com/Exikle/Artemis-Cluster>
- **CNI**: Cilium (BGP) | **Ingress**: Envoy Gateway (Gateway API / HTTPRoute)

---

## Hardware

### Control Planes (Metal)

- **3× Lenovo M710q** — `talos-cp-01/02/03`
    - Boot: 256GB NVMe | Ceph OSD: 256GB SATA SSD | VLAN 1099 (LAB, static IPs)

### Workers (Proxmox VMs on `pantheon`)

- **talos-w-01, talos-w-02**: 32GB RAM, 6 vCPU (NUMA), 64GB disk
- **talos-gpu-01**: 32GB RAM, 6 vCPU, ASRock Arc A380 passthrough (6GB)

### Proxmox Host (`pantheon`)

- HPE ML150 G9 | 2× Xeon E5-2620 v3 (24 cores total) | Proxmox PVE 6.17.2
- HP RAID card (P440/H240) must be in HBA mode (ssacli or F9 BIOS) to expose raw disks

### Network

- **UCG-Max** (10.10.99.1): WAN/NAT, VLANs, DHCP, BGP AS 64533, DNS (dcunha.io via external-dns-unifi)
- **Mikrotik CRS309**: L2 switch only

### Storage

- **TrueNAS** (`atlas`, 10.10.99.100): ~41TB usable (3× RAIDZ2), NFS `/mnt/atlas/media` → `/media` in pods
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

DNS: UCG-Max @ 10.10.99.1 (authoritative for dcunha.io).

---

## Repo Structure

```
.agents/          # AI agent instructions and skills
bootstrap/        # Bootstrap justfile — run order matters
talos/            # Node configs (controlplane.yaml, worker.yaml)
kubernetes/
  apps/           # App HelmReleases by namespace
  components/     # Shared kustomize components (volsync, etc.)
  flux/sync/      # Entrypoint Kustomization → kubernetes/apps
  mod.just        # Kubernetes task recipes
mise.toml         # Tool version management
```

---

## Flux Operator Architecture

- Flux Operator manages Flux lifecycle; FluxInstance defines sync config
- FluxInstance lives in `kubernetes/apps/flux-system/flux-instance/`
- Sync entrypoint: `kubernetes/flux/sync/` → `kubernetes/apps`
- Upgrade Flux: change version in `flux-instance.yaml` — operator handles rolling update
- Bootstrap secrets: applied via `just bootstrap` using `op inject` — not in Git
- `flux-instance` Kustomization: `prune: false` — never prune Flux itself

---

## Namespaces & Apps

| Namespace          | Key Apps                                                                                         |
| ------------------ | ------------------------------------------------------------------------------------------------ |
| `flux-system`      | flux-operator, flux-instance, flux-monitor, notifications                                        |
| `media`            | Sonarr ×3, Radarr, Jellyfin, Jellyseerr, SABnzbd, qBittorrent+Gluetun, Prowlarr, autobrr, Bazarr |
| `cortex`           | Open WebUI, Pipelines, mem0, Qdrant, SearXNG, ToolHive (3 gateways + 8 MCP servers)              |
| `home-automation`  | Home Assistant, Frigate, Mosquitto, Zigbee2MQTT, Matter Server                                   |
| `observability`    | VictoriaMetrics stack, Grafana Operator, VictoriaLogs                                            |
| `security`         | Kanidm (OIDC)                                                                                    |
| `rook-ceph`        | Rook-Ceph cluster                                                                                |
| `network`          | Envoy Gateway, Cloudflare tunnel                                                                 |
| `external-secrets` | External Secrets Operator (1Password)                                                            |

---

## Dev Tooling (mise)

```toml
uv = "latest"
"pipx:flux-local" = "latest"
talhelper = "latest"
prettier = "latest"
node = "latest"
helm = "4.1.4"
k9s = "latest"
gh = "latest"
"github:mitsuhiko/minijinja" = "latest"
```

Task runner: `just` (`bootstrap/mod.just`, `kubernetes/mod.just`)

---

## Bootstrap Order

1. `talosctl apply-config --insecure --nodes <cp-ip> --file talos/controlplane.yaml`
2. `talosctl apply-config --insecure --nodes <worker-ip> --file talos/worker.yaml`
3. `just bootstrap` — k8s bootstrap, kubeconfig, namespaces, secrets via `op inject`, helmfile
   (Cilium → CoreDNS → cert-manager → external-secrets → 1Password → flux-operator → flux-instance)

---

## Known Hardware & Ops Issues

- **Proxmox HP RAID**: ssacli or F9 BIOS → HBA mode to expose raw disks
- **Rook-Ceph mgr/mon crash**: remove `device_failure_prediction_mode: local` from cephConfig (requires `diskprediction_local` module which isn't enabled)
- **SABnzbd P2 expired**: NewsDemon `news.newsdemon.com` expired 2026-04-21 — remove from SABnzbd servers
- **Eaton UPS**: batteries dead — not providing real protection
