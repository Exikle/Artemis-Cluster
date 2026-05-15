<div align="center">

<img src="docs/static/images/logo.png" width="80px" height="80px"/> &nbsp; **The Artemis Cluster**

_... where YAML is law, Renovate never sleeps, and 2am is just debugging hours._

---

</div>

<div align="center">

[![Talos](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dtalos_version&style=for-the-badge&logo=talos&logoColor=white&color=blue&label=talos)](https://www.talos.dev/)&nbsp;&nbsp;
[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&color=blue&label=k8s)](https://kubernetes.io/)&nbsp;&nbsp;
[![Flux](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fflux_version&style=for-the-badge&logo=flux&logoColor=white&color=blue&label=flux)](https://fluxcd.io)&nbsp;&nbsp;
[![Renovate](https://img.shields.io/github/actions/workflow/status/Exikle/Artemis-Cluster/renovate.yaml?branch=main&label=&logo=renovatebot&style=for-the-badge&color=blue)](https://github.com/Exikle/Artemis-Cluster/actions/workflows/renovate.yaml)

[![Home-Internet](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.dcunha.io%2Fapi%2Fv1%2Fendpoints%2Fcore_ping%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=ubiquiti&logoColor=white&label=Home%20Internet)](https://status.dcunha.io)&nbsp;&nbsp;
[![Status-Page](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.dcunha.io%2Fapi%2Fv1%2Fendpoints%2Fcore_status-page%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=statuspage&logoColor=white&label=Status%20Page)](https://status.dcunha.io)&nbsp;&nbsp;
[![Alertmanager](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.dcunha.io%2Fapi%2Fv1%2Fendpoints%2Fcore_heartbeat%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=prometheus&logoColor=white&label=Alertmanager)](https://status.dcunha.io)

[![Age-Days](https://kromgo.dcunha.io/cluster_age_days?format=badge)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Node-Count](https://kromgo.dcunha.io/cluster_node_count?format=badge)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Pod-Count](https://kromgo.dcunha.io/cluster_pod_count?format=badge)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![CPU-Usage](https://kromgo.dcunha.io/cluster_cpu_usage?format=badge)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Memory-Usage](https://kromgo.dcunha.io/cluster_memory_usage?format=badge)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Alerts](https://kromgo.dcunha.io/cluster_alert_count?format=badge)](https://github.com/kashalls/kromgo)

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
│   ├── 📁 cortex                 # AI stack — Open WebUI, Qdrant, SearXNG, ToolHive MCP servers
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

Kubernetes nodes run on VLAN 1099 (LAB, `10.10.99.0/24`). Home-automation pods attach a secondary interface to VLAN 1152 (IOT, `10.10.152.0/24`) via [Multus](https://github.com/k8snetworkplumbingwg/multus-cni) for direct device access (Frigate, Home Assistant, Zigbee2MQTT).

BGP peers between UCG-Max (AS 64533) and all six Talos nodes distribute LoadBalancer service IPs into the LAB routing table.

---

## 🤝 Acknowledgments

A huge thanks to the following people whose work has been an invaluable reference:

- [onedr0p/home-ops](https://github.com/onedr0p/home-ops)
- [bjw-s-labs/home-ops](https://github.com/bjw-s-labs/home-ops)
- [joryirving/home-ops](https://github.com/joryirving/home-ops)
- [Christian Lempa](https://www.youtube.com/@christianlempa) — whose YouTube content helped demystify a lot of the early infrastructure concepts
- [TechnoTim](https://www.youtube.com/@TechnoTim) — for countless practical homelab guides that made the learning curve far less steep

And to the broader [Home Operations](https://discord.gg/home-operations) Discord community — thanks to everyone openly sharing their setups and knowledge.

---

## 📝 License

This repository is available under the WTFPL License. See [LICENSE](./LICENSE) for details.
