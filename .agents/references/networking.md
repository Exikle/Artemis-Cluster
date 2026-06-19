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

## Multus — IoT VLAN Attachment

Pods that need direct L2 access to IoT VLAN 1152 (e.g. home-automation apps, Matter Server) get a
secondary `net1` interface via Multus. The network attachment definition is named `iot` in `kube-system`.

### Annotation format

```yaml
defaultPodOptions:
    annotations:
        k8s.v1.cni.cncf.io/networks: |-
            [{
              "name": "iot",
              "namespace": "kube-system",
              "ips": [
                "10.10.152.<N>/24",
                "fd00:10:10:152::<N>/64"
              ],
              "mac": "02:xx:xx:xx:xx:xx"
            }]
```

- IPv4: `10.10.152.<N>/24` — pick next available in the static range
- IPv6: `fd00:10:10:152::<N>/64` — always matches IPv4 last octet (`<N>` in decimal, no conversion needed for values ≤ 255)
- MAC: static, manually assigned — use `02:` prefix (locally administered unicast); keep unique across all pods
- Gateway (IPv4): `10.10.152.1` (UCG-Max IoT VLAN interface)
- IPv6 default route: learned via RA from UCG-Max (`fd00:10:10:152::1`)

### Assigned addresses

| App            | IPv4            | IPv6                  | MAC               |
| -------------- | --------------- | --------------------- | ----------------- |
| home-assistant | 10.10.152.10/24 | fd00:10:10:152::10/64 | 02:4d:60:06:55:be |
| matter-server  | 10.10.152.11/24 | fd00:10:10:152::11/64 | 02:0c:d8:a2:91:8f |
| homebridge     | 10.10.152.12/24 | fd00:10:10:152::12/64 | 02:ee:bb:51:b4:dc |
| esphome        | 10.10.152.13/24 | fd00:10:10:152::13/64 | 02:4d:60:0e:5e:0d |

Next available: `.14` / `::14`

### Thread / Matter context

The IoT VLAN hosts the Thread mesh via three border routers:

| Device            | IP            | MAC               | Link-local IPv6           | TBR policy  |
| ----------------- | ------------- | ----------------- | ------------------------- | ----------- |
| Apple TV Basement | 10.10.152.166 | 48:e1:5c:76:22:2b | fe80::4ae1:5cff:fe76:222b | Restrictive |
| Nest Hub #EB53    | 10.10.152.86  | 38:86:f7:0e:96:93 | fe80::3a86:f7ff:fe0e:9693 | Open        |
| Nest Hub #2960    | 10.10.152.99  | d8:eb:46:d6:b9:4c | fe80::daeb:46ff:fed6:b94c | Open        |

Thread network: `NEST-PAN-0751`, Channel 22, Extended PAN ID `7fd8ca45c6794b90`

Apple TV blocks third-party Matter commissioning via Thread. Route through a Nest Hub instead.

To route the Matter Server pod to Thread devices via a Google Nest Hub (open TBR):

```yaml
# init container in matter-server helmrelease
initContainers:
    thread-route:
        image:
            repository: alpine
            tag: 3.21.3
        command:
            - sh
            - -c
            - ip -6 route add fc00::/7 via fe80::3a86:f7ff:fe0e:9693 dev net1 || true
        securityContext:
            capabilities:
                add: ["NET_ADMIN"]
                drop: ["ALL"]
```

`fc00::/7` covers all ULA addresses including any Thread mesh prefix. The more specific
`fd00:10:10:152::/64` (IoT VLAN) takes precedence automatically — only Thread ULA traffic goes via the TBR.
