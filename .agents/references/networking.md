# Reference: Networking — Artemis-Cluster

## Gateways

| Gateway            | Namespace | Reach                      | Use for                |
| ------------------ | --------- | -------------------------- | ---------------------- |
| `internal-gateway` | `network` | LAN only (UCG-Max DNS)     | Internal-only services |
| `external-gateway` | `network` | Cloudflare tunnel (public) | Public-facing services |

Routes are defined **inline in helmrelease values** under `route.app:` — not as standalone HTTPRoute files.

### Gateway selection rules

**k8s-native apps** — use whichever gateway matches the desired exposure:

```yaml
parentRefs:
    - name: external-gateway # public-facing
      namespace: network
```

**Non-k8s services** (LXC, Proxmox, TrueNAS, etc.) exposed via `external-endpoints` — must use **both** gateways:

```yaml
parentRefs:
    - name: external-gateway
      namespace: network
      sectionName: https
    - name: internal-gateway
      namespace: network
      sectionName: https
```

Why: UCG-Max split-horizon DNS resolves `*.dcunha.io` to `internal-gateway` (10.10.99.98) for LAN clients. External clients go through Cloudflare → `external-gateway` (10.10.99.97). If only `external-gateway` is set, internal clients get 404 because the route isn't attached to `internal-gateway`.

## Cluster-Internal Traffic

Always use `svc.cluster.local` for pod-to-pod communication — never external hostnames:

```text
<app>.<namespace>.svc.cluster.local
```

## VLANs

| VLAN | Name | Subnet          | Purpose                          |
| ---- | ---- | --------------- | -------------------------------- |
| 1001 | HME  | 10.10.1.0/24    | Trusted home                     |
| 1099 | LAB  | 10.10.99.0/24   | Servers, K8s nodes               |
| 1152 | IOT  | 10.10.152.0/24  | IoT (reachable from worker pods) |
| 1151 | GST  | 10.10.151.0/24  | Guest                            |
| 1088 | TST  | 192.168.88.0/24 | Testing                          |

DNS: UCG-Max @ 10.10.99.1 (authoritative for dcunha.io).

## External DNS

`external-dns-unifi` writes DNS records to UCG-Max automatically from HTTPRoute hostnames.
