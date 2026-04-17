<div align="center">

<img src="docs/static/images/logo.png" align="center" width="144px" height="144px"/>

### The Artemis Cluster! :octocat:

_... where YAML is law, Renovate never sleeps, and 2am is just debugging hours._

</div>

<div align="center">

[![Talos](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dtalos_version&style=for-the-badge&logo=talos&logoColor=white&color=blue&label=%20)](https://www.talos.dev/)&nbsp;&nbsp;
[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&color=blue&label=%20)](https://kubernetes.io/)&nbsp;&nbsp;
[![Flux](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fflux_version&style=for-the-badge&logo=flux&logoColor=white&color=blue&label=%20)](https://fluxcd.io)&nbsp;&nbsp;
[![Renovate](https://img.shields.io/github/actions/workflow/status/Exikle/Artemis-Cluster/renovate.yaml?branch=main&label=&logo=renovatebot&style=for-the-badge&color=blue)](https://github.com/Exikle/Artemis-Cluster/actions/workflows/renovate.yaml)

</div>

<div align="center">

[![Home-Internet](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.dcunha.io%2Fapi%2Fv1%2Fendpoints%2Fcore_ping%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=ubiquiti&logoColor=white&label=Home%20Internet)](https://status.dcunha.io)&nbsp;&nbsp;
[![Status-Page](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.dcunha.io%2Fapi%2Fv1%2Fendpoints%2Fcore_status-page%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=statuspage&logoColor=white&label=Status%20Page)](https://status.dcunha.io)&nbsp;&nbsp;
[![Alertmanager](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.dcunha.io%2Fapi%2Fv1%2Fendpoints%2Fcore_heartbeat%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=prometheus&logoColor=white&label=Alertmanager)](https://status.dcunha.io)

</div>

<div align="center">

[![Age-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_age_days&style=flat-square&label=Age)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Uptime-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_uptime_days&style=flat-square&label=Uptime)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Node-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_node_count&style=flat-square&label=Nodes)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Pod-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_pod_count&style=flat-square&label=Pods)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![CPU-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_cpu_usage&style=flat-square&label=CPU)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Memory-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_memory_usage&style=flat-square&label=Memory)](https://github.com/kashalls/kromgo)

<!-- [![Power-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_power_usage&style=flat-square&label=Power)](https://github.com/kashalls/kromgo)&nbsp;&nbsp; -->

[![Alerts](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.dcunha.io%2Fcluster_alert_count&style=flat-square&label=Alerts)](https://github.com/kashalls/kromgo)

</div>

---

## 📖 Overview

This repository manages my homelab Kubernetes cluster built on [TalosOS](https://www.talos.dev/), following Infrastructure as Code (IaC) and GitOps practices. The setup consists of three bare-metal control plane nodes and three VM workers (including one GPU worker), with all configurations version-controlled and automatically deployed via [FluxCD](https://fluxcd.io/).

I didn't start from a cluster template — this was built from the ground up, learning as I went. Over time I've gradually aligned the structure and conventions with what the [Home Operations](https://discord.gg/home-operations) community has collectively settled on, borrowing ideas and patterns from repos I admire rather than forking from any single starting point.

---

## ⛵ Kubernetes

### Components Explained

The cluster is organized into logical namespaces for maintainability and separation of concerns:

- **kube-system:** The foundation layer — cluster networking ([Cilium](https://cilium.io/)), core DNS ([CoreDNS](https://coredns.io/)), multi-network ([Multus](https://github.com/k8snetworkplumbingwg/multus-cni)), GPU support ([intel-gpu-resource-driver](https://github.com/intel/intel-resource-drivers-for-kubernetes)), and cluster utilities (reloader, reflector, descheduler, spegel).
- **network:** Ingress via [Envoy Gateway](https://gateway.envoyproxy.io/), DNS automation via [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) (Cloudflare + UniFi), and Cloudflare Tunnel.
- **cert-manager:** Automated TLS certificates via Let's Encrypt.
- **observability:** Full monitoring stack — [Prometheus](https://prometheus.io/), [Grafana](https://grafana.com/), [Victoria Logs](https://victoriametrics.com/products/victorialogs/), [Fluent Bit](https://fluentbit.io/), [Gatus](https://github.com/TwiN/gatus), [Kromgo](https://github.com/kashalls/kromgo), KEDA, and UniFi Poller.
- **rook-ceph / openebs-system / volsync-system:** Block storage, local storage, and PVC backup/restore.
- **home-automation:** Home Assistant, Frigate, ESPHome, Zigbee2MQTT, Mosquitto, Matter Server, Homebridge, Node-RED.
- **media:** Full arr stack, Jellyfin, download clients, and supporting tooling.
- **external-secrets:** Secrets from [1Password Connect](https://developer.1password.com/docs/connect/), plus age-encrypted bootstrap secrets.

### Directories

This Git repository contains the following directories under [Kubernetes](./kubernetes/).

```sh
📁 kubernetes
├── 📁 apps
│   ├── 📁 actions-runner-system  # Self-hosted GitHub runners
│   ├── 📁 cert-manager           # TLS certificate management
│   ├── 📁 external-endpoints     # ExternalName services for off-cluster resources
│   ├── 📁 external-secrets       # 1Password Connect secrets provider
│   ├── 📁 flux-system            # Flux Operator + FluxInstance
│   ├── 📁 home-automation        # Home Assistant, Frigate, ESPHome, Zigbee, etc.
│   ├── 📁 kube-system            # Cilium, CoreDNS, Multus, GPU driver, utilities
│   ├── 📁 media                  # Arr stack, Jellyfin, download clients
│   ├── 📁 network                # Envoy Gateway, ExternalDNS, Cloudflare Tunnel
│   ├── 📁 observability          # Prometheus, Grafana, Victoria Logs, Gatus, Kromgo
│   ├── 📁 openebs-system         # Local storage provisioner
│   ├── 📁 rook-ceph              # Distributed block storage
│   ├── 📁 system-upgrade         # Tuppr (Talos/K8s automated upgrades)
│   └── 📁 volsync-system         # PVC backup/restore (Kopia)
├── 📁 components     # Reusable Kustomize components
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
