# VLANs & Routing

## Network Devices

| Device                            | Role                                                                             |
| --------------------------------- | -------------------------------------------------------------------------------- |
| UniFi Cloud Gateway Max (UCG-Max) | WAN/NAT, L3 gateway for all VLANs, DHCP server, BGP (FRR), DNS, UniFi controller |
| Mikrotik CRS309-1G-8S+            | L2 switch only — no routing, no BGP, no IPs                                      |
| UniFi US-48 PoE 500W              | L2 switch (upstream: UCG-Max port 4)                                             |
| UniFi US-16 PoE 150W              | L2 switch (upstream: US-48 port 13)                                              |

The UCG-Max replaced pfSense as the network gateway. The Mikrotik is now a pure L2 switch downstream of the UCG-Max on VLAN 1099 (LAB).

---

## VLANs

| Name    | VLAN ID | Subnet          | Gateway      | DHCP Range | Purpose                 |
| ------- | ------- | --------------- | ------------ | ---------- | ----------------------- |
| LAN     | 1       | 192.168.1.0/24  | 192.168.1.1  | .50–.200   | Legacy/default          |
| HME     | 1001    | 10.10.1.0/24    | 10.10.1.1    | .50–.200   | Trusted home users      |
| TST     | 1088    | 192.168.88.0/24 | 192.168.88.1 | .50–.200   | Testing                 |
| LAB     | 1099    | 10.10.99.0/24   | 10.10.99.1   | .50–.70    | Servers, K8s nodes      |
| GST     | 1151    | 10.10.151.0/24  | 10.10.151.1  | .50–.200   | Guest                   |
| IOT     | 1152    | 10.10.152.0/24  | 10.10.152.1  | .50–.200   | IoT devices             |
| TRANSIT | 99      | 172.16.99.0/30  | —            | None       | UCG-Max ↔ Mikrotik link |

---

## Key Static IPs (LAB — 10.10.99.0/24)

| Host             | IP              | Notes                                          |
| ---------------- | --------------- | ---------------------------------------------- |
| UCG-Max          | 10.10.99.1      | Gateway, DNS, BGP peer                         |
| talos-cp-01      | 10.10.99.101    | Control plane                                  |
| talos-cp-02      | 10.10.99.102    | Control plane                                  |
| talos-cp-03      | 10.10.99.103    | Control plane                                  |
| pantheon         | 10.10.99.104    | Proxmox host                                   |
| talos-w-01       | 10.10.99.201    | Worker                                         |
| talos-w-02       | 10.10.99.202    | Worker                                         |
| talos-gpu-01     | 10.10.99.203    | GPU worker                                     |
| atlas (TrueNAS)  | 10.10.99.100    | NFS: `/mnt/atlas/media`                        |
| kube-api VIP     | 10.10.99.99     | Kubernetes API server (L2 via Cilium)          |
| Internal gateway | 10.10.99.98     | Envoy internal-gateway LoadBalancer IP         |
| External gateway | 10.10.99.97     | Envoy external-gateway LoadBalancer IP         |
| LB pool          | 10.10.99.71–.96 | Available for additional LoadBalancer services |

---

## Multi-Network (Multus + IOT VLAN)

Home-automation pods (Frigate, Home Assistant, Zigbee2MQTT, etc.) attach a secondary interface to VLAN 1152 (IOT) via [Multus](https://github.com/k8snetworkplumbingwg/multus-cni). This gives them a direct L2 presence on the IOT network for device discovery and communication without going through NAT.

The Multus `NetworkAttachmentDefinition` for IOT is defined in `kubernetes/apps/kube-system/multus/networks/iot.yaml`.

---

## UCG-Max Management

```bash
# SSH
ssh root@10.10.99.1

# BGP status
vtysh -c 'show bgp summary'

# UniFi admin
# Cloud account: dixondcunha@gmail.com
# Web UI: https://10.10.99.1 (or unifi.ui.com)

# MongoDB (for advanced debugging)
mongo --port 27117 ace
```
