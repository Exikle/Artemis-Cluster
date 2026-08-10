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

## CoreDNS

Manifest: `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml`. It is the upstream
coredns chart with the home-operations plugin chain; the two `template` plugins between
`autopath` and `forward` are ours and are load-bearing. Their rationale lives here, not in
the manifest.

### Plugin order is load-bearing

```text
kubernetes → autopath → template(ANY ANY dcunha.io) → template(ANY AAAA dcunha.io) → forward
```

Both templates must stay **after** `kubernetes` and in **this relative order**. Changing
either position reintroduces a cluster-wide outage described below.

### Guard 1 — `template ANY ANY dcunha.io`, NXDOMAIN for 2+ label names

Talos 1.14 applies the DHCPv4 search domain, so every pod's `resolv.conf` now ends with
`dcunha.io`. With `ndots:5`, a name like `pooler-rw.database.svc.cluster.local` (4 dots)
walks the search list before being tried absolute — and `<anything>.dcunha.io` resolves via
a Cloudflare wildcard, so upstream answered `172.64.80.1` instead of the ClusterIP. glibc
callers (immich, paperless, zigbee, forgesync…) broke; busybox/musl was unaffected because
it tries the absolute name first.

It is not only cluster names: `ghcr.io` (1 dot, also under `ndots:5`) becomes
`ghcr.io.dcunha.io`, which the wildcard answers, and TLS then fails on the cert mismatch —
that took out every OCIRepository at once. The bug class is "a name that already contains a
dot got the search domain appended", so NXDOMAIN anything with 2+ labels ahead of
`dcunha.io`. Real hosts here are single-label (`git`/`id`/`artemis`.dcunha.io) and keep
resolving normally.

NXDOMAIN specifically — a NODATA would let the search-domain walk continue.

### Guard 2 — `template ANY AAAA dcunha.io`, NODATA for AAAA

Internal split-horizon only overrides the A record: `external.dcunha.io` (which
git/registry/… CNAME to) answers `10.10.99.97` internally, but the public Cloudflare AAAA
`2606:4700:…` passes through untouched. That address is unreachable from the pod network, and
any client that tries it first dies with "network is unreachable" — which is why oci-push
failed intermittently across different tasks and both registries rather than on any one host
or tool. NODATA (NOERROR, no answer, no fallthrough) means callers only ever see the
reachable IPv4. The `authority` SOA lets resolvers negative-cache the NODATA rather than
re-asking on every lookup.

### Do not widen the AAAA guard to all zones

`buroa/k8s-gitops` runs the same template unscoped (`ANY AAAA`, every zone) and placed
first in the chain. Do not copy that here:

- **The pod network is not IPv6-free.** The `iot` multus NAD gives home-assistant,
  matter-server, esphome, homebridge and victoria-logs real ULA addresses on
  `fd00:10:10:152::/64` with a v6 default route, and **Matter/Thread is IPv6-only by
  protocol** (see _Multus — IoT VLAN Attachment_ below). Those peers are discovered over
  mDNS rather than through CoreDNS — the pods run `hosts: files dns` with no mDNS NSS
  module, and the ULA range has no unicast DNS records at all — so a blanket AAAA NODATA is
  not _known_ to break them, but the margin is thin and a silently unreachable Matter fabric
  is expensive to debug. The scoped guard already fixes the only observed failure.
- **Position matters even if widened.** Placed first, it would answer AAAA for
  `ghcr.io.dcunha.io` with NODATA before Guard 1 could return NXDOMAIN, re-breaking the
  search-domain hijack.

### OPEN (2026-08-10) — the same failure exists for external zones

Guard 2 is scoped to `dcunha.io`, and the note above that it "already fixes the only observed
failure" is no longer true. The underlying defect is broader: **pods get IPv6 addresses and
resolvers hand back AAAA for external zones, but IPv6 egress does not work at all.** Measured
from a throwaway pod in `forgejo`:

```console
$ curl -6 -o /dev/null -w '%{http_code}' --max-time 8 https://registry-1.docker.io/v2/
000                     # network is unreachable
$ curl -4 -o /dev/null -w '%{http_code}' --max-time 8 https://registry-1.docker.io/v2/
401                     # reachable
$ dig +short AAAA dl.google.com | head -1
2607:f8b0:4023:1804::5d # returned, and unusable
```

Any client that prefers the AAAA fails with `connect: network is unreachable`. It is
intermittent only because clients differ in whether they fall back to IPv4. Confirmed
casualties, all previously written off as unrelated flakes:

- buildkit resolving `docker.io/docker/dockerfile:1` and `data.forgejo.org/oci/alpine:3.24`,
  which fails a container build outright
- Flux `OCIRepository` pulls for `forgejo-runner`, `tekton-runner` and `buildkit`
- `containers` CI installing tools from `dl.google.com` / GitHub releases

**Do not fix this by widening Guard 2.** The constraint in the section above still holds —
the `iot` multus NAD gives real ULA addresses to home-assistant, matter-server, esphome,
homebridge and victoria-logs, and Matter/Thread is IPv6-only by protocol. A blanket AAAA
NODATA trades a build problem for a silently dead Matter fabric.

Options, roughly in order of preference:

1. **Fix IPv6 egress on the UCG-Max** — the actual defect. Everything else is a workaround,
   and this is the only option that leaves the pod network honest.
2. **Extend the scoped guard to the specific external zones that only ever need IPv4**
   (`docker.io`, `ghcr.io`, `data.forgejo.org`, `dl.google.com`, `githubusercontent.com`).
   Keeps the Matter/Thread ULA path untouched, at the cost of a list that needs maintaining.
3. **Leave it and rely on retries.** `container-build` and `container-validate` carry
   `retries: 2` on every network-touching task for this reason, and it is why CI passes on a
   second attempt. It hides the problem rather than solving it.

Until this is resolved, treat a one-off `network is unreachable` in any build, pull or tool
download as this issue and retry before investigating further.

### Verifying a CoreDNS change

Validate offline before touching cluster DNS — a bad Corefile crashloops every DNS pod. The
chart does **not** run `configBlock` through `tpl` (`{{ .configBlock | indent 12 }}`), so Go
template vars like `{{ .Zone }}` reach the Corefile literally and CoreDNS expands them at
query time; Flux `postBuild` uses `${...}` and does not touch them either.

```bash
helm template coredns oci://ghcr.io/coredns/charts/coredns --version <ver> \
  -f <(yq eval '.spec.values' kubernetes/apps/kube-system/coredns/app/helmrelease.yaml) \
  --show-only templates/configmap.yaml
```

Then run the rendered Corefile under podman (drop the `kubernetes`/`health`/`prometheus`
plugins and repoint `forward` at a public resolver) and check each case. Expected results:

| Query                    | Expected           |
| ------------------------ | ------------------ |
| `A ghcr.io`              | real answer        |
| `AAAA ghcr.io`           | real answer        |
| `A git.dcunha.io`        | 10.10.99.97        |
| `AAAA git.dcunha.io`     | NOERROR, 0 answers |
| `A ghcr.io.dcunha.io`    | NXDOMAIN           |
| `AAAA ghcr.io.dcunha.io` | NXDOMAIN           |

Confirm live from a **glibc** pod (`kubectl exec -n database postgres-1 -c postgres`) — musl
images resolve differently and will hide the original bug class.

## BGP / Control-Plane Endpoint

The UCG-Max runs **FRRouting 10.1.2** and you can `ssh root@10.10.99.1` to inspect it
(`vtysh -c "show bgp ipv4 unicast summary"`, `ip route show <ip>`). Verified state as of
2026-07-27:

| Item                | Value                                                           |
| ------------------- | --------------------------------------------------------------- |
| UCG ASN / router-id | `64533` / `10.10.99.1`                                          |
| Cluster ASN         | `64512` (Cilium, `CiliumBGPClusterConfig`)                      |
| Peers               | eBGP to all 6 nodes (peer entry named `mikrotik` — legacy name) |
| Hold / keepalive    | `9s` / `3s`                                                     |

`artemis.dcunha.io` → `10.10.99.99` is a **Cilium LoadBalancer Service** (`kube-api` in
`kube-system`) selecting apiserver pods with `externalTrafficPolicy: Local`, advertised over
BGP. **ECMP already works** — the UCG shows 3 `multipath` paths and 3 kernel next-hops, one
per control plane. There is no `maximum-paths` line in the FRR config and none is needed.

BGP negotiates the **minimum** hold time of the two peers, so cluster-side timers win: the UCG
offers 180/60 and Cilium proposes 9/3. Do not "fix" this on the router. Before 9/3 it was 90s,
which meant a hard control-plane failure (power loss, not a graceful withdrawal) black-holed
roughly a third of API traffic for up to 90 seconds.

### Investigated and declined: anycast control-plane endpoint via Talos native BGP

**Investigated 2026-07-27. Decided against — do not re-open without new information.** The
findings below are recorded so the analysis is not re-derived. This section assumes no prior
context.

The gap: Cilium cannot advertise `10.10.99.99` unless the API server is already up, so the
endpoint is unavailable during a cold start or a Cilium outage. That is why
`cluster.yaml.j2` points workers at a hardcoded `https://10.10.99.101:6443` (cp-01)
instead of the hostname — a single point of failure for worker joins.

Talos 1.14 added **native BGP**, which runs on the node independently of Kubernetes and could
therefore advertise the endpoint before the cluster exists. Upstream reference:
onedr0p/home-ops commits `680f24b4`, `12de489c`, `3f7a73a5`.

**Why declined:** the gap only bites during a cold start or a total Cilium outage. ECMP already
works and hold timers are already 9s, so steady-state failover is fine. Every design that
closes it costs either a new VLAN or a permanent cluster-wide scheduling constraint (below).
Not worth it for the exposure.

#### Config document naming — version trap

| Talos version                  | Kind                | `name:` field      |
| ------------------------------ | ------------------- | ------------------ |
| `v1.14.0-beta.0` (what we run) | `BGPPeerConfig`     | none (unnamed doc) |
| Talos `main`                   | `BGPInstanceConfig` | **required**       |

The upstream commits above use the old name. Re-check this when upgrading past 1.14 — a config
written against one name is rejected by the other.

#### The core obstacle: two sessions collide

FRR keys neighbours by peer IP, and `BGPPeerConfig` has **no update-source / source-address
field** (`routerID` only sets the BGP router-id; `routeSource` is RTA_PREFSRC for installed
routes, not the session source). So a Talos session sources from the node's `bond0.1099`
address — the same source Cilium already uses — and the second TCP connection is torn down by
BGP collision resolution. Any working design must give the two sessions distinct source
addresses, or eliminate one of them.

**Unnumbered peering does not solve this for IPv4.** Verified against the v1.14.0-beta.0
source: `BuildOriginatedPath` (`internal/app/machined/pkg/controllers/network/internal/bgp/bgp.go`)
originates an IPv4 prefix as `RF_IPv4_UC` with `NEXT_HOP` `0.0.0.0`, relying on GoBGP's
next-hop-self per peer. Over an IPv6 link-local transport there is no IPv4 address to
substitute, and RFC 5549 extended-nexthop is not implemented anywhere in the BGP sources
(`ExtendedNexthop|RFC5549|Capabilit` matches nothing). `neighbor.link:` is also not true
unnumbered — Talos resolves the peer's link-local from the kernel neighbour table (populated by
RAs) and sets it as a concrete `NeighborAddress`. It would work for an **IPv6** anycast prefix
only.

#### The two viable designs

**A — peering VLAN (upstream parity).** A new VLAN carries the Talos sessions, giving them
distinct source addresses; Cilium BGP stays on all six nodes. Costs a new UniFi network trunked
to the three control planes, and moves the peering addresses out of 10.10.99.x (the anycast IP
itself can still be 10.10.99.99). Upstream's `RoutingRuleConfig` + table-100 route **is
required** here — not because upstream is multi-VLAN, but because once peering moves off
`bond0.1099` the anycast-sourced replies leave via the wrong interface and reach the UCG
asymmetrically. (`rp_filter` is `2`/loose on `br1099`, so uRPF itself would pass; the stateful
firewall is the risk.)

**B — split BGP by role.** Restrict `CiliumBGPClusterConfig.nodeSelector` to workers and give
control planes only the Talos session. One session per node, so nothing collides: no new VLAN,
no `RoutingRuleConfig` (peering and anycast both on `bond0.1099`, so return traffic is
symmetric), and all addressing stays in 10.10.99.x. Costs: `internal-gateway` runs 2 replicas
and currently keeps one on a control plane, so it must be pinned to workers — and thereafter
**any `externalTrafficPolicy: Local` LoadBalancer whose pod lands on a control plane is
silently unreachable**, a standing footgun needing a scheduling constraint.

Supporting data as of 2026-07-27: every LoadBalancer Service is `etp: Local` except
`observability/truenas-exporter` (`Cluster`). Only `network/internal-gateway` has a
control-plane endpoint; all others are worker-backed. Control planes are schedulable
(`taints: {}`) and carry 22–35 pods each.

#### UCG operational constraints

- **The live BGP config is not `/etc/frr/frr.conf`.** That file is near-empty and
  `/etc/frr/daemons` says `bgpd=no`, yet `bgpd` runs — unifi-core starts it directly and loads
  config via vtysh. The persisted source is the UniFi controller's Mongo store
  (`/data/unifi/data/db/ace/`). **vtysh edits are wiped on the next controller provision**, so
  neighbour changes must be uploaded through the UniFi UI's BGP config file. SSH is
  verification-only.
- `bfdd=no` on the UCG, so the sub-second BFD failover that `BGPPeerConfig` supports is
  unavailable without enabling the daemon first.

If either design is ever executed: add UCG neighbours **one at a time**, verifying with
`vtysh -c "show bgp ipv4 unicast summary"` between each, and keep the Cilium-advertised
`10.10.99.99` working throughout so there is always a path to the API. Taking over
`10.10.99.99` from Cilium means shrinking the `CiliumLoadBalancerIPPool` block
(`10.10.99.71`–`10.10.99.99`) and deleting the `kube-api` Service, or the two fight over the
prefix — note that deleting the Service also drops the external-dns record for
`artemis.dcunha.io`, which would then need a static entry on the UCG.

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
| victoria-logs  | 10.10.152.14/24 | fd00:10:10:152::14/64 | 02:1a:c3:7f:9e:44 |

Next available: `.15` / `::15`

### Thread / Matter context

The IoT VLAN hosts the Thread mesh via three border routers:

| Device            | IP            | MAC               | Link-local IPv6           | TBR policy  |
| ----------------- | ------------- | ----------------- | ------------------------- | ----------- |
| Apple TV Basement | 10.10.152.166 | 48:e1:5c:76:22:2b | fe80::4ae1:5cff:fe76:222b | Restrictive |
| Nest Hub #EB53    | 10.10.152.86  | 38:86:f7:0e:96:93 | fe80::3a86:f7ff:fe0e:9693 | Open        |
| Nest Hub #2960    | 10.10.152.99  | d8:eb:46:d6:b9:4c | fe80::daeb:46ff:fed6:b94c | Open        |

Thread network: `NEST-PAN-0751`, Channel 22, Extended PAN ID `7fd8ca45c6794b90`

Apple TV blocks third-party Matter commissioning via Thread. Route through a Nest Hub instead.

### Thread routing is RA-learned — no init container needed

Verified 2026-08-03: matter-server picks up the Thread mesh prefix automatically from the
border routers' Router Advertisements. Its live routing table on `net1`:

| Prefix                            | Source                          |
| --------------------------------- | ------------------------------- |
| `fd00:10:10:152::/64`             | IoT VLAN (NAD)                  |
| `fd00:10:10:152::11/128`          | static, from the NAD annotation |
| `fd00:10:10:152:c:d8ff:fea2:918f` | SLAAC, derived from its MAC     |
| `fd90:bec8:b07e::/64`             | **Thread mesh, via RA**         |

An earlier revision of this doc suggested a `thread-route` init container adding
`fc00::/7 via fe80::3a86:f7ff:fe0e:9693 dev net1` with `NET_ADMIN`. **That is not deployed
and is not needed** — nothing in `kubernetes/` references it. Reach for it only if the
`fd90:bec8:b07e::/64` route is genuinely absent (check
`kubectl exec -n home-automation <matter-server-pod> -- cat /proc/net/ipv6_route`; the image
has no `ip` binary, so `ip -6 route` returns empty and is not evidence of a missing route).

### CoreDNS plays no part in Matter

Matter/Thread discovery is mDNS over multicast (`ff02::fb`) using the CHIP stack's own
resolver, and the pods run `hosts: files dns` with no mDNS NSS module. The
`fd00:10:10:152::/64` and Thread ULA ranges have no unicast DNS records in either direction.
So CoreDNS changes cannot affect the Matter fabric — but see _Do not widen the AAAA guard_
above for why the AAAA guard still stays scoped.

`fc00::/7` covers all ULA addresses including any Thread mesh prefix. The more specific
`fd00:10:10:152::/64` (IoT VLAN) takes precedence automatically — only Thread ULA traffic goes via the TBR.
