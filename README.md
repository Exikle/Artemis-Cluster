<div align="center">

<img src="docs/static/images/logo.png" align="center" width="144px" height="144px"/>

### The Artemis Cluster! :octocat:

_... managed with Flux, Renovate, and GitHub Actions_

</div>

<div align="center">

[![Talos](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dtalos_version&style=for-the-badge&logo=talos&logoColor=white&color=blue&label=%20)](https://www.talos.dev/)&nbsp;&nbsp;
[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&color=blue&label=%20)](https://kubernetes.io/)&nbsp;&nbsp;
[![Flux](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fflux_version&style=for-the-badge&logo=flux&logoColor=white&color=blue&label=%20)](https://fluxcd.io)&nbsp;&nbsp;
[![Renovate](https://img.shields.io/github/actions/workflow/status/Exikle/Artemis-Cluster/renovate.yaml?branch=main&label=&logo=renovatebot&style=for-the-badge&color=blue)](https://github.com/Exikle/Artemis-Cluster/actions/workflows/renovate.yaml)

</div>

<div align="center">

[![Home-Internet](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.dcunha.io%2Fapi%2Fv1%2Fendpoints%2Fexternal_ping%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=ubiquiti&logoColor=white&label=Home%20Internet)](https://status.dcunha.io)&nbsp;&nbsp;
[![Status-Page](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.dcunha.io%2Fapi%2Fv1%2Fendpoints%2Fexternal_status-page%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=statuspage&logoColor=white&label=Status%20Page)](https://status.dcunha.io)&nbsp;&nbsp;
<!-- [![Alertmanager](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.k13.dev%2Fapi%2Fv1%2Fendpoints%2Fexternal_heartbeat%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=prometheus&logoColor=white&label=Alertmanager)](https://status.dcunha.io) -->

</div>

<div align="center">

[![Age-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_age_days&style=flat-square&label=Age)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Uptime-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_uptime_days&style=flat-square&label=Uptime)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Node-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_node_count&style=flat-square&label=Nodes)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Pod-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_pod_count&style=flat-square&label=Pods)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![CPU-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_cpu_usage&style=flat-square&label=CPU)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Memory-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_memory_usage&style=flat-square&label=Memory)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Power-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_power_usage&style=flat-square&label=Power)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Alerts](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_alert_count&style=flat-square&label=Alerts)](https://github.com/kashalls/kromgo)

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
