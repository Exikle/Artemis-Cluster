<div align="center">

<img src="assets/logo.png" align="center" width="144px" height="144px"/>

### The Artemis Cluster

_... where YAML is law, Renovate never sleeps, and 2am <br>is just debugging hours._

</div>

<div align="center">

[![Talos](https://kromgo.dcunha.io/badges/talos_version)](https://talos.dev)&nbsp;&nbsp;
[![Kubernetes](https://kromgo.dcunha.io/badges/kubernetes_version)](https://kubernetes.io)&nbsp;&nbsp;
[![Flux](https://kromgo.dcunha.io/badges/flux_version)](https://fluxcd.io)&nbsp;&nbsp;
[![Renovate](https://kromgo.dcunha.io/badges/renovate_status)](https://git.dcunha.io/exikle/Artemis-Cluster)

[![Home-Internet](https://kromgo.dcunha.io/badges/core_ping)](https://status.dcunha.io)&nbsp;&nbsp;
[![Status-Page](https://kromgo.dcunha.io/badges/core_status_page)](https://status.dcunha.io)&nbsp;&nbsp;
[![Alertmanager](https://kromgo.dcunha.io/badges/core_heartbeat)](https://status.dcunha.io)

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

## 🗂️ Layout

```sh
📁 kubernetes
├── 📁 apps        # Flux-managed applications, one directory per namespace
├── 📁 components  # Reusable Kustomize components (kopiur, zeroscaler, postgres, tinyauth)
└── 📁 flux        # Flux sync entrypoint -> kubernetes/apps

📁 talos
├── 📁 nodes       # Per-node machine config as Jinja2 templates
└── 📁 schematics  # Image schematics — extensions and kernel args per node type

📁 ansible         # Host config for what is not in Kubernetes — atlas, pantheon, the Forgejo LXC
📁 terraform       # OpenTofu — proxmox and unifi stacks
```

Only `kubernetes/` is reconciled by Flux. `talos/`, `ansible/` and `terraform/` are run by hand
through `just`.

---

## 🔩 Hardware

| Device                                        | Disk                                                                                                   | RAM        | Purpose                                                 |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ---------- | ------------------------------------------------------- |
| 3× Lenovo M710q (`talos-cp-01/02/03`)         | 256GB NVMe MZVLW256HEHP (miroir nvme pool) + boot SATA SSD (cp-02/03 860 EVO 500GB, cp-01 860 QVO 1TB) | 16GB       | Kubernetes control plane                                |
| 2× Proxmox VM on `pantheon` (`talos-w-01/02`) | Virtualized                                                                                            | 32GB       | Kubernetes worker                                       |
| 1× Proxmox VM on `pantheon` (`talos-gpu-01`)  | Virtualized                                                                                            | 32GB       | Kubernetes GPU worker (ASRock Arc A380 6GB passthrough) |
| 1× Gigabyte C246N-WU2 (`ymir`)                | 128GB SATA M.2 SSD                                                                                     | 16GB       | Kubernetes worker (Xeon E-2124G, UHD P630 iGPU)         |
| 1× HPE ML150 G9 (`pantheon`)                  | T-FORCE 1TB SSD                                                                                        | 192GB      | Proxmox virtualization host                             |
| 1× Supermicro (`atlas`)                       | 3× RAIDZ2 6-wide (~41TB usable)                                                                        | 94.3GB ECC | TrueNAS SCALE — NAS / media storage                     |

Every Kubernetes node runs Talos Linux.

---

## 🌐 Networking

| Device                  | Role                                                        |
| ----------------------- | ----------------------------------------------------------- |
| UniFi Cloud Gateway Max | WAN/NAT, L3 gateway, DHCP, BGP (FRR), DNS, UniFi controller |
| Mikrotik CRS309-1G-8S+  | L2 switch only — downstream of UCG-Max on VLAN 1099 (LAB)   |
| UniFi US-48 PoE 500W    | L2 switch (upstream: UCG-Max)                               |
| UniFi US-16 PoE 150W    | L2 switch (upstream: US-48)                                 |

---

## 🙏 Acknowledgments

Thanks to the following for their work and shared knowledge:

- [onedr0p/home-ops](https://github.com/onedr0p/home-ops)
- [bjw-s-labs/home-ops](https://github.com/bjw-s-labs/home-ops)
- [joryirving/home-ops](https://github.com/joryirving/home-ops)
- [Christian Lempa](https://www.youtube.com/@christianlempa)
- [TechnoTim](https://www.youtube.com/@TechnoTim)
- [Home Operations](https://discord.gg/home-operations) Discord community

---

## 📄 License

This repository is available under the WTFPL License. See [LICENSE](./LICENSE) for details.
