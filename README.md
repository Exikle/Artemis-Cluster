<div align="center">

<img src="docs/static/images/logo.png" align="center" width="144px" height="144px"/>

### The Artemis Cluster! :octocat:

_... managed with Flux, Renovate, and GitHub Actions_ 🤖

</div>

---

## 📖 Overview

This repository manages my homelab Kubernetes cluster built on [TalosOS](https://www.talos.dev/), following Infrastructure as Code (IaC) and GitOps practices. The setup consists of three bare-metal control plane nodes and two VM workers, with all configurations version-controlled and automatically deployed via [FluxCD](https://fluxcd.io/).

---

## ⛵ Kubernetes

### Components Explained

The cluster is organized into logical directories for maintainability and separation of concerns:

- **System:** The foundation layer that handles cluster networking ([Cilium](https://cilium.io/)), core DNS ([CoreDNS](https://coredns.io/)), and storage drivers ([Rook-Ceph](https://rook.io/), [NFS](https://github.com/kubernetes-csi/csi-driver-nfs)).
- **Network:** Handles ingress traffic using [Envoy Gateway](https://gateway.envoyproxy.io/), DNS automation via [ExternalDNS](https://github.com/kubernetes-sigs/external-dns), and certificates with [cert-manager](https://cert-manager.io/).
- **Observability:** A complete monitoring stack including [Prometheus](https://prometheus.io/), [Grafana](https://grafana.com/), and [Loki](https://grafana.com/oss/loki/) to ensure the cluster stays healthy.
- **Apps:** The actual workloads—media servers, home automation, developer tools, and databases.

### Core Stack

- [actions-runner-controller](https://github.com/actions/actions-runner-controller): Self-hosted Github runners for CI/CD.
- [cert-manager](https://github.com/cert-manager/cert-manager): Automated SSL certificate management.
- [cilium](https://github.com/cilium/cilium): eBPF-based container networking (CNI).
- [envoy-gateway](https://gateway.envoyproxy.io/): Next-gen Gateway API implementation.
- [external-secrets](https://github.com/external-secrets/external-secrets): Kubernetes secrets managed via [Bitwarden Secrets Manager](https://bitwarden.com/products/secrets-manager/).
- [rook-ceph](https://rook.io/): Cloud-native storage orchestrator for distributed block storage.
- [sops](https://github.com/getsops/sops): Encrypted secrets stored in Git.

### Directories

This Git repository contains the following directories under [Kubernetes](./kubernetes/).

```sh
📁 kubernetes
├── 📁 apps           # Applications (Home Assistant, Plex, etc.)
├── 📁 components     # Reusable Kustomize overlays
├── 📁 flux           # Flux system configuration
├── 📁 kube-system    # Core system components (Cilium, CoreDNS)
├── 📁 network        # Ingress, Gateway API, Cloudflare
├── 📁 observability  # Monitoring stack (Prometheus, Grafana)
└── 📁 storage-system # Rook-Ceph, VolSync
```

### How It Works

1. Make changes to manifests in this repository—no manual edits on nodes.
2. [FluxCD](https://fluxcd.io/) automatically syncs the cluster state with Git.
3. If a rebuild is needed, redeploy TalosOS and point Flux at this repo—everything returns as configured.

---

## 🔧 Hardware

| Device                      | Count | Disk Configuration           | Ram    | Operating System | Purpose                 |
|-----------------------------|-------|------------------------------|--------|------------------|-------------------------|
| Lenovo M720q                | 3     | 256GB SSD + 1TB NVMe         | 16GB      | Talos Linux      | Control Plane           |
| Proxmox VM (HPE ML150 G8)   | 2     | Virtualized Storage          | 8GB      | Talos Linux      | Workers                 |
| HPE ML150 G8                | 1     | -                            | 192GB  | Proxmox          | Virtualization Host     |
| Supermicro Storage Server   | 1     | 41TB Raw Capacity            | -      | TrueNAS          | NAS / Backup Target     |

---

## 🤝 Acknowledgments

This project is heavily inspired by the [onedr0p/home-ops](https://github.com/onedr0p/home-ops) repository and the amazing [Home Operations](https://discord.gg/home-operations) Discord community. Thanks to everyone sharing their setups and knowledge!

---

## 📝 License

This repository is available under the WTFPL License. See [LICENSE](./LICENSE) for details.
