# BGP

Cilium BGP distributes Kubernetes LoadBalancer service IPs into the LAB routing table. This replaces L2 announcements for the LB IP pool — devices on other VLANs (HME, LAN) reach LoadBalancer IPs by routing through the UCG-Max which learns the routes via BGP.

## Architecture

```
UCG-Max (AS 64533)
  ├── peer: talos-cp-01  10.10.99.101
  ├── peer: talos-cp-02  10.10.99.102
  ├── peer: talos-cp-03  10.10.99.103
  ├── peer: talos-w-01   10.10.99.201
  ├── peer: talos-w-02   10.10.99.202
  └── peer: talos-gpu-01 10.10.99.203
```

All 6 nodes peer with the UCG-Max. Nodes advertise the LB IP pool (`10.10.99.71–10.10.99.99`) via BGP. The UCG-Max installs these routes and distributes them to other VLANs.

## Cilium BGP Configuration

BGP is configured via `CiliumBGPClusterConfig` and `CiliumBGPPeerConfig` resources in `kubernetes/apps/kube-system/cilium/app/networking.yaml`. Nodes participating in BGP must have the label `bgppolicy: enabled`, which is applied to all nodes via the Talos node config.

## Known Behaviour

Devices **on the LAB subnet** (10.10.99.0/24) cannot reach LB IPs directly. The LB IP pool is within the LAB subnet range but the UCG-Max does not L2-proxy ARP for these addresses. Devices on HME, LAN, and other VLANs route through the UCG-Max and work fine.

This is an intentional BGP-only design.

## Checking BGP Status

```bash
# On UCG-Max
ssh root@10.10.99.1
vtysh -c 'show bgp summary'
vtysh -c 'show ip route bgp'

# From a cluster node
kubectl -n kube-system exec ds/cilium -- cilium bgp peers
kubectl -n kube-system exec ds/cilium -- cilium bgp routes
```

## Adding a New LoadBalancer IP

Add the IP to the `CiliumLoadBalancerIPPool` resource in the Cilium networking manifest. Cilium will advertise it to all BGP peers automatically once a service claims it.
