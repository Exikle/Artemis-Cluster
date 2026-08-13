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

| VLAN | Name | Subnet          | IPv6                    | Purpose                          |
| ---- | ---- | --------------- | ----------------------- | -------------------------------- |
| 1001 | HME  | 10.10.1.0/24    | none                    | Trusted home                     |
| 1099 | LAB  | 10.10.99.0/24   | `2607:fea8:4e1f:3800::` | Servers, K8s nodes               |
| 1152 | IOT  | 10.10.152.0/24  | `2607:fea8:4e1f:3801::` | IoT (reachable from worker pods) |
| 1151 | GST  | 10.10.151.0/24  | none                    | Guest                            |
| 1088 | TST  | 192.168.88.0/24 | none                    | Testing                          |

DNS: UCG-Max @ 10.10.99.1 (authoritative for dcunha.io).

IPv6 prefixes come from Rogers DHCPv6-PD on the UCG WAN and **rotate** — never hardcode a GUA
from them. VLAN 1152 also carries the legacy ULA `fd00:10:10:152::/64`, still advertised by the
Mikrotik and still used by the `iot` NAD's static addresses.

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

### Guard 2 is now unscoped (2026-08-10) — `template ANY AAAA .`

It was scoped to `dcunha.io` until 2026-08-10 and is now `.`, every zone. The cluster has no
usable IPv6 for ordinary pods, so NODATA is the truthful answer to any AAAA — this stops
clients dialling addresses that can only fail.

Two constraints hold it in place:

- **Position is still load-bearing.** It must stay **after** Guard 1. Placed first it would
  answer AAAA for `ghcr.io.dcunha.io` with NODATA before Guard 1 could return NXDOMAIN,
  re-breaking the search-domain hijack. Verified after widening: `ghcr.io.dcunha.io` returns
  NXDOMAIN for both A and AAAA.
- **It intercepts `cluster.local` AAAA too**, because `template` precedes `kubernetes` in
  CoreDNS's plugin chain. Harmless while services are IPv4-only — NODATA is correct — but this
  is the first thing to revert if the cluster is ever dual-stacked.

An earlier revision of this doc argued against widening, on the grounds that the `iot` multus
NAD gives five pods real ULA addresses and Matter/Thread is IPv6-only by protocol. That concern
does not survive contact with how Matter actually resolves: discovery is mDNS over `ff02::fb`
via the CHIP stack's own resolver, the pods run `hosts: files dns` with no mDNS NSS module, and
neither the IoT ULA nor the Thread mesh range has any unicast DNS record in either direction.
CoreDNS cannot reach the Matter fabric. See _CoreDNS plays no part in Matter_ below.

**Revisit when the cluster is dual-stacked.** This guard is a workaround for pods having no
IPv6, not a permanent position — once pods can actually route IPv6, it becomes a lie that will
break real AAAA lookups. Remove it as the last step of that migration.

### PARTIALLY RESOLVED (2026-08-10) — the same failure exists for external zones

Guard 2 is scoped to `dcunha.io`, and the note above that it "already fixes the only observed
failure" is no longer true. The underlying defect is broader: **resolvers hand back AAAA for
external zones, but pod IPv6 egress does not work at all.** Measured from a throwaway pod in
`forgejo`:

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

**Option 1 was done on 2026-08-10 and fixed only half of it.** The root cause was never the
UCG — it was the Mikrotik CRS309 advertising itself as an IPv6 default router on VLAN 1152
(`/ipv6 nd`, stock `interface=all`, `ra-lifetime=30m`) while having no `::/0` of its own. The
UCG now has Rogers DHCPv6-PD and is the sole IPv6 router on 1099/1152, and **nodes have working
IPv6 egress** (`curl -6` → 200 from host netns via `bond0.1099`).

**Pods still do not.** Cilium runs `enable-ipv6: false` with v4-only pod/service CIDRs, so an
ordinary pod has no IPv6 address and no IPv6 route — only the five macvlan pods on the `iot`
NAD have v6, and only on that VLAN. Every casualty listed above is unchanged.

Remaining options:

1. **Dual-stack the cluster.** The honest fix. Needs ULA pod/service CIDRs (`fd00:42::/56`,
   `fd00:43::/108`) because the Rogers prefix rotates, plus a rolling node reset —
   `spec.podCIDRs` is assigned at registration and existing nodes will not gain a second
   family. Blocked on deciding stable node IPv6 addressing: UniFi's IPv6 Interface Type is a
   single choice, so a network cannot have both PD and a static ULA.
2. ~~**Widen Guard 2 to all zones.**~~ **DONE 2026-08-10** — see _Guard 2 is now unscoped_
   above. Verified: AAAA returns NODATA for every external zone, A records unchanged, Guard 1
   still returns NXDOMAIN for `ghcr.io.dcunha.io`, `cluster.local` unaffected, and `curl` to
   both `registry-1.docker.io/v2/` and `ghcr.io/v2/` returns 401 (reachable).
3. ~~Extend the scoped guard to specific external zones~~ — moot, superseded by 2.
4. ~~Leave it and rely on retries~~ — the `retries: 2` on `container-build` and
   `container-validate` can stay, but should no longer be masking this.

**This is a workaround, not the fix.** Option 1 remains the real answer and is deliberately
deferred: it needs a rolling node re-registration, and all three Ceph OSDs sit on the control
planes (`ceph health` was already `HEALTH_WARN` on 2026-08-10). Revisit when Ceph is healthy
and the node-addressing question has an answer — and remove Guard 2's widening as the final
step of that migration.

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
| Peers               | eBGP to all 7 nodes (peer entry named `mikrotik` — legacy name) |
| Hold / keepalive    | `9s` / `3s`                                                     |

### Editing the BGP config — it is not a file on disk

`/etc/frr/frr.conf` on the UCG holds only stock defaults (`log syslog informational`) and
nothing else. The real config lives in the **UniFi controller's MongoDB**
(`/data/unifi/data/db/ace`) and is pushed into FRR by the controller. Nothing renders it to
disk, so `grep`-ing the filesystem for a neighbor address finds only DNS leases and logs.

There is no form-based BGP UI. The config is a **raw FRR file uploaded** in the Network app
under **Settings → Routing → BGP**, containing just the `router bgp` block — the controller
generates the surrounding `frr version` / `hostname` / `domainname` lines itself.

A `vtysh -c "configure terminal" -c "router bgp 64533" -c "neighbor ..."` change applies
immediately and survives an FRR restart, but the controller **overwrites it on the next
provision**. Use vtysh only to get a peer up in the moment; the upload is the durable edit.

Adding a node means two neighbor lines plus one line in `address-family ipv4 unicast`:

```
 neighbor 10.10.99.204 remote-as 64512
 neighbor 10.10.99.204 description ymir
 !
 address-family ipv4 unicast
  neighbor 10.10.99.204 soft-reconfiguration inbound
 exit-address-family
```

Cilium needs no matching change — `CiliumBGPClusterConfig` selects on
`kubernetes.io/os: linux`, so every node is already a speaker and the session establishes as
soon as the neighbor exists on the UCG. To dump the current config for re-upload:
`ssh root@10.10.99.1 'vtysh -c "show running-config"' | sed -n '/^router bgp/,/^exit$/p'`

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

### Thread routing rides the default route — do not remove it

**Superseded 2026-08-10.** The claim below that the mesh prefix is RA-learned no longer holds:
the Thread network has since renumbered to `fdf4:6f68:f055:1::/64`, and `net1` carries
`accept_ra_rt_info_max_plen=0`, so the border routers' RFC 4191 route-information options are
**ignored**. There is no specific route for the mesh prefix — Matter reaches Thread devices via
the pod's IPv6 **default route**. That makes `::/0` on `net1` load-bearing for the Matter
fabric.

This is why the NAD's `::/0` gateway had to be repointed at the UCG rather than deleted when
the Mikrotik was silenced. It is also half of the trap below.

### The `sbr` link-local trap — read before changing RA on VLAN 1152

The `iot` NAD chains the `sbr` (source-based routing) plugin, which creates
`ip -6 rule: from fd00:10:10:152::10 lookup 101` and places `fe80::/64 dev net1` in **table 101
only**. Matter uses net1's _link-local_ as source when talking to link-local peers, which does
not match that rule, falls through to `main` — where the RA-learned default route is the only
net1 entry catching it.

Consequence: **removing the last IPv6 default router from VLAN 1152 breaks Matter**, even
though nothing about the change looks DNS- or Matter-related. Observed 2026-08-10 after
`/ipv6 nd add interface=IOT ra-lifetime=0s` on the Mikrotik with no other router on the VLAN —
`send ENETUNREACH fe80::...%net1:5540`, ~25/min, devices cycling offline and taking ~45s each
to fall back to their ULA. Reverted with `/ipv6 nd remove [find interface=IOT]`; recovered in
~3 minutes.

Safe sequence, if this ever comes up again:

1. Make sure another router is already advertising a default on the VLAN — verify with
   `kubectl exec -n home-automation deploy/home-assistant -c app -- ip -6 route show | grep default`
2. Demote first (`ra-preference=low`), verify clients moved, and only then `ra-lifetime=0s`
3. To drop the default route from the **Talos hosts** without touching pods, use the sysctl
   `net.ipv6.conf.bond0/1152.accept_ra_defrtr=0` — macvlan children have their own netns and
   `accept_ra`, so it cannot affect the Matter pods

### Historical: Thread routing was RA-learned (2026-08-03)

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
