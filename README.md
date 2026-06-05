<div align="center">

<img src="docs/static/images/logo.png" align="center" width="144px" height="144px"/>

### The Artemis Cluster

_... where YAML is law, Renovate never sleeps, and 2am <br>is just debugging hours._

</div>

<div align="center">

[![Talos](https://kromgo.dcunha.io/badges/talos_version)](https://talos.dev)&nbsp;&nbsp;
[![Kubernetes](https://kromgo.dcunha.io/badges/kubernetes_version)](https://kubernetes.io)&nbsp;&nbsp;
[![Flux](https://kromgo.dcunha.io/badges/flux_version)](https://fluxcd.io)&nbsp;&nbsp;
[![Renovate](https://kromgo.dcunha.io/badges/renovate_status)](https://git.dcunha.io/exikle/Artemis-Cluster)

</div>

<div align="center">

[![Home-Internet](https://kromgo.dcunha.io/badges/core_ping)](https://status.dcunha.io)&nbsp;&nbsp;
[![Status-Page](https://kromgo.dcunha.io/badges/core_status_page)](https://status.dcunha.io)&nbsp;&nbsp;
[![Alertmanager](https://kromgo.dcunha.io/badges/core_heartbeat)](https://status.dcunha.io)

</div>

<div align="center">

[![Age](https://kromgo.dcunha.io/badges/cluster_birth_age)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Uptime](https://kromgo.dcunha.io/badges/cluster_uptime_age)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Nodes](https://kromgo.dcunha.io/badges/cluster_node_count)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Pods](https://kromgo.dcunha.io/badges/cluster_pod_count)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![CPU](https://kromgo.dcunha.io/badges/cluster_cpu_usage)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Memory](https://kromgo.dcunha.io/badges/cluster_memory_usage)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Alerts](https://kromgo.dcunha.io/badges/cluster_alert_count)](https://github.com/home-operations/kromgo)

</div>

---

## 📖 Overview

Artemis is my homelab Kubernetes cluster, built on [Talos Linux](https://www.talos.dev/) and managed entirely through Git. Three bare-metal control planes, three VM workers (one with a GPU), all reconciled automatically by [Flux CD](https://fluxcd.io/) — push to main, it shows up in the cluster.

---

## ⛵ Kubernetes

### Directories

```sh
📁 kubernetes
├── 📁 apps
│   ├── 📁 actions-runner-system  # Self-hosted GitHub Actions runners for CI workflows
│   ├── 📁 cert-manager           # Automated TLS certificates via Let's Encrypt
│   ├── 📁 cortex                 # AI stack — Open WebUI, SearXNG, text-embeddings-inference, ToolHive (9 MCP servers)
│   ├── 📁 default                # Personal apps — Immich (photos), Komga (comics), Bookboss (books)
│   ├── 📁 external-endpoints     # ExternalName services bridging off-cluster resources into the mesh
│   ├── 📁 external-secrets       # 1Password-backed ExternalSecret operator for all cluster secrets
│   ├── 📁 flux-system            # Flux Operator, FluxInstance, and GitOps sync entrypoint
│   ├── 📁 home-automation        # Home Assistant, Frigate, Zigbee2MQTT, Mosquitto, Matter Server, ESPHome
│   ├── 📁 kube-system            # Cilium (CNI/BGP), CoreDNS, Multus, Intel GPU driver, cluster utilities
│   ├── 📁 media                  # Arr stack, Jellyfin, SABnzbd, qBittorrent+Gluetun, Prowlarr, Bazarr
│   ├── 📁 network                # Envoy Gateway ingress, ExternalDNS (Cloudflare + UniFi), Cloudflare Tunnel
│   ├── 📁 observability          # Prometheus, Grafana, VictoriaLogs, Fluent Bit, Gatus, Kromgo, KEDA
│   ├── 📁 openebs-system         # Local-path storage provisioner for single-node PVCs
│   ├── 📁 rook-ceph              # Distributed block storage across 3 OSD nodes (one per control plane)
│   ├── 📁 security               # Pocket-ID OIDC provider for cluster-wide SSO
│   ├── 📁 system-upgrade         # Tuppr — automated Talos and Kubernetes version upgrades
│   └── 📁 volsync-system         # PVC backup and restore via Kopia snapshots
├── 📁 components     # Reusable Kustomize components (volsync, etc.)
└── 📁 flux           # Flux sync entrypoint → kubernetes/apps
```

---

## 🔧 Hardware

| Device                                     | Count | Disk                                          | RAM        | OS            | Purpose                                                 |
| ------------------------------------------ | ----- | --------------------------------------------- | ---------- | ------------- | ------------------------------------------------------- |
| Lenovo M710q (`talos-cp-01/02/03`)         | 3     | 256GB NVMe (boot) + 256GB SATA SSD (Ceph OSD) | 16GB       | Talos Linux   | Kubernetes Control Plane                                |
| Proxmox VM on `pantheon` (`talos-w-01/02`) | 2     | Virtualized                                   | 32GB       | Talos Linux   | Kubernetes Worker                                       |
| Proxmox VM on `pantheon` (`talos-gpu-01`)  | 1     | Virtualized                                   | 32GB       | Talos Linux   | Kubernetes GPU Worker (ASRock Arc A380 6GB passthrough) |
| HPE ML150 G9 (`pantheon`)                  | 1     | T-FORCE 1TB SSD                               | 192GB      | Proxmox       | Virtualization Host                                     |
| Supermicro (`atlas`)                       | 1     | 3× RAIDZ2 6-wide (~41TB usable)               | 94.3GB ECC | TrueNAS SCALE | NAS / Media Storage                                     |

---

## 🌐 Networking

| Device                  | Role                                                        |
| ----------------------- | ----------------------------------------------------------- |
| UniFi Cloud Gateway Max | WAN/NAT, L3 gateway, DHCP, BGP (FRR), DNS, UniFi controller |
| Mikrotik CRS309-1G-8S+  | L2 switch only — downstream of UCG-Max on VLAN 1099 (LAB)   |
| UniFi US-48 PoE 500W    | L2 switch (upstream: UCG-Max)                               |
| UniFi US-16 PoE 150W    | L2 switch (upstream: US-48)                                 |

---

## 🤝 Acknowledgments

Thanks to the following for their work and shared knowledge:

- [onedr0p/home-ops](https://github.com/onedr0p/home-ops)
- [bjw-s-labs/home-ops](https://github.com/bjw-s-labs/home-ops)
- [joryirving/home-ops](https://github.com/joryirving/home-ops)
- [Christian Lempa](https://www.youtube.com/@christianlempa)
- [TechnoTim](https://www.youtube.com/@TechnoTim)
- [Home Operations](https://discord.gg/home-operations) Discord community

---

## 📝 License

This repository is available under the WTFPL License. See [LICENSE](./LICENSE) for details.
