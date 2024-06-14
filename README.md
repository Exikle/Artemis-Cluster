<div align="center">

<img src="https://raw.githubusercontent.com/onedr0p/home-ops/main/docs/src/assets/logo.png" align="center" width="144px" height="144px"/>

### The Artemis Cluster! :octocat:

_... managed with Flux, Renovate, and GitHub Actions_ 🤖

</div>

<!-- <div align="center">

[![Talos](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dtalos_version&style=for-the-badge&logo=talos&logoColor=white&color=blue&label=%20)](https://www.talos.dev/)&nbsp;&nbsp;
[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&color=blue&label=%20)](https://www.talos.dev/)&nbsp;&nbsp;
[![Renovate](https://img.shields.io/github/actions/workflow/status/onedr0p/home-ops/renovate.yaml?branch=main&label=&logo=renovatebot&style=for-the-badge&color=blue)](https://github.com/onedr0p/home-ops/actions/workflows/renovate.yaml)

</div>

<div align="center">

[![Home-Internet](https://img.shields.io/uptimerobot/status/m793494864-dfc695db066960233ac70f45?color=brightgreeen&label=Home%20Internet&style=for-the-badge&logo=v&logoColor=white)](https://status.devbu.io)&nbsp;&nbsp;
[![Status-Page](https://img.shields.io/uptimerobot/status/m793599155-ba1b18e51c9f8653acd0f5c1?color=brightgreeen&label=Status%20Page&style=for-the-badge&logo=statuspage&logoColor=white)](https://status.devbu.io)&nbsp;&nbsp;
[![Alertmanager](https://img.shields.io/uptimerobot/status/m793494864-dfc695db066960233ac70f45?color=brightgreeen&label=Alertmanager&style=for-the-badge&logo=prometheus&logoColor=white)](https://status.devbu.io)

</div>

<div align="center">

[![Age-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_age_days&style=flat-square&label=Age)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Uptime-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_uptime_days&style=flat-square&label=Uptime)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Node-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_node_count&style=flat-square&label=Nodes)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Pod-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_pod_count&style=flat-square&label=Pods)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![CPU-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_cpu_usage&style=flat-square&label=CPU)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Memory-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_memory_usage&style=flat-square&label=Memory)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Power-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_power_usage&style=flat-square&label=Power)](https://github.com/kashalls/kromgo/)

</div> -->

---

## 📖 Overview

This is a mono repository for my home infrastructure and Kubernetes cluster. I try to adhere to Infrastructure as Code (IaC) and GitOps practices using tools like [Kubernetes](https://kubernetes.io/), [Flux](https://github.com/fluxcd/flux2), [Renovate](https://github.com/renovatebot/renovate), and [GitHub Actions](https://github.com/features/actions).

---

## ⛵ Kubernetes

### Core Components

- [actions-runner-controller](https://github.com/actions/actions-runner-controller): Self-hosted Github runners.
- [cert-manager](https://github.com/cert-manager/cert-manager): Creates SSL certificates for services in my cluster.
- [cilium](https://github.com/cilium/cilium): Internal Kubernetes container networking interface.
<!-- - [cloudflared](https://github.com/cloudflare/cloudflared): Enables Cloudflare secure access to certain ingresses. -->
- [democratic-csi](https://github.com/democratic-csi/democratic-csi): Allows mounting TrueNAS ISCSI onto kubernetes clusters.
- [external-dns](https://github.com/kubernetes-sigs/external-dns): Automatically syncs ingress DNS records to a DNS provider.
- [external-secrets](https://github.com/external-secrets/external-secrets): Managed Kubernetes secrets using [Bitwarden Secrets Manager](https://bitwarden.com/products/secrets-manager/).
<!-- - [rook](https://github.com/rook/rook): Distributed block storage for peristent storage. -->
- [sops](https://github.com/getsops/sops): Managed secrets for Kubernetes and Terraform which are commited to Git.
<!-- - [spegel](https://github.com/spegel-org/spegel): Stateless cluster local OCI registry mirror.
- [volsync](https://github.com/backube/volsync): Backup and recovery of persistent volume claims. -->

<!-- ### GitOps -->

<!-- [Flux](https://github.com/fluxcd/flux2) watches the clusters in my [kubernetes](./kubernetes/) folder (see Directories below) and makes the changes to my clusters based on the state of my Git repository.

The way Flux works for me here is it will recursively search the `kubernetes/${cluster}/apps` folder until it finds the most top level `kustomization.yaml` per directory and then apply all the resources listed in it. That aforementioned `kustomization.yaml` will generally only have a namespace resource and one or many Flux kustomizations (`ks.yaml`). Under the control of those Flux kustomizations there will be a `HelmRelease` or other resources related to the application which will be applied.

[Renovate](https://github.com/renovatebot/renovate) watches my **entire** repository looking for dependency updates, when they are found a PR is automatically created. When some PRs are merged Flux applies the changes to my cluster. -->

### Directories

This Git repository contains the following directories under [Kubernetes](./kubernetes/).

```sh
📁 kubernetes
├── 📁 apps           # applications
├── 📁 bootstrap      # bootstrap procedures
├── 📁 flux           # core flux configuration
└── 📁 ...             # other clusters
```

<!-- ### Networking -->

<!-- <details>
  <summary>Click here to see my high-level network diagram</summary>

  <img src="https://raw.githubusercontent.com/onedr0p/home-ops/main/docs/src/assets/network-topology.png" align="center" width="600px" alt="dns"/>
</details> -->

---

<!-- ## ☁️ Cloud Dependencies -->
<!--
While most of my infrastructure and workloads are self-hosted I do rely upon the cloud for certain key parts of my setup. This saves me from having to worry about three things. (1) Dealing with chicken/egg scenarios, (2) services I critically need whether my cluster is online or not and (3) The "hit by a bus factor" - what happens to critical apps (e.g. Email, Password Manager, Photos) that my family relies on when I no longer around.

Alternative solutions to the first two of these problems would be to host a Kubernetes cluster in the cloud and deploy applications like [HCVault](https://www.vaultproject.io/), [Vaultwarden](https://github.com/dani-garcia/vaultwarden), [ntfy](https://ntfy.sh/), and [Gatus](https://gatus.io/); however, maintaining another cluster and monitoring another group of workloads would be more work and probably be more or equal out to the same costs as described below. -->

<!-- | Service                                         | Use                                                               | Cost           |
|-------------------------------------------------|-------------------------------------------------------------------|----------------|
| [Bitwarden](https://bitwarden.com/)             | Secrets with [External Secrets](https://external-secrets.io/)     | Free           |
| [Cloudflare](https://www.cloudflare.com/)       | Domain                                                            | Free           |
| [GCP](https://cloud.google.com/)                | Voice interactions with Home Assistant over Google Assistant      | Free           |
| [GitHub](https://github.com/)                   | Hosting this repository and continuous integration/deployments    | Free           | -->
<!-- | [Migadu](https://migadu.com/)                   | Email hosting                                                     | ~$20/yr        | -->
<!-- | [Pushover](https://pushover.net/)               | Kubernetes Alerts and application notifications                   | $5 OTP         | -->
<!-- | [UptimeRobot](https://uptimerobot.com/)         | Monitoring internet connectivity and external facing applications | ~$58/yr        | -->
<!-- |                                                 |                                                                   | Total: ~$10/mo | -->

<!-- --- -->

<!-- ## 🌐 DNS

In my cluster there are two [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) instances deployed. One is deployed with the [ExternalDNS webhook provider for UniFi](https://github.com/kashalls/external-dns-unifi-webhook) which syncs DNS records to my UniFi router. The other ExternalDNS instance syncs DNS records to Cloudflare only when the ingresses and services have an ingress class name of `external` and contain an ingress annotation `external-dns.alpha.kubernetes.io/target`. All local clients on my network use my UniFi router as the upstream DNS server.

--- -->

<!-- ## 🔧 Hardware

<details>
  <summary>Click here to see my server rack</summary>

  <img src="https://raw.githubusercontent.com/onedr0p/home-ops/main/docs/src/assets/rack.png" align="center" width="200px" alt="dns"/>
</details>

| Device                      | Count | OS Disk Size | Data Disk Size               | Ram  | Operating System | Purpose                 |
|-----------------------------|-------|--------------|------------------------------|------|------------------|-------------------------|
| Intel NUC8i5BEH             | 3     | 1TB SSD      | 1TB NVMe (rook-ceph)         | 64GB | Talos            | Kubernetes Controllers  |
| Intel NUC8i7BEH             | 3     | 1TB SSD      | 1TB NVMe (rook-ceph)         | 64GB | Talos            | Kubernetes Workers      |
| PowerEdge T340              | 1     | 2TB SSD      |                              | 64GB | Ubuntu 22.04     | NFS + Backup Server     |
| Lenovo SA120                | 1     | -            | 10x22TB ZFS (mirrored vdevs) | -    | -                | DAS                     |
| PiKVM (RasPi 4)             | 1     | 64GB (SD)    | -                            | 4GB  | PiKVM (Arch)     | KVM                     |
| TESmart 8 Port KVM Switch   | 1     | -            | -                            | -    | -                | Network KVM (for PiKVM) |
| UniFi UDMP Max              | 1     | -            | 2x12TB HDD                   | -    | -                | Router & NVR            |
| UniFi US-16-XG              | 1     | -            | -                            | -    | -                | 10Gb Core Switch        |
| UniFi USW-Enterprise-24-PoE | 1     | -            | -                            | -    | -                | 2.5Gb PoE Switch        |
| UniFi USP PDU Pro           | 1     | -            | -                            | -    | -                | PDU                     |
| APC SMT1500RM2U             | 1     | -            | -                            | -    | -                | UPS                     |

--- -->
