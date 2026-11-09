# Reference: Networking — Artemis-Cluster

## Gateways

| Gateway            | Namespace | LB IP         | Hostnames                                     | Reach                                 | Use for                     |
| ------------------ | --------- | ------------- | --------------------------------------------- | ------------------------------------- | --------------------------- |
| `internal-gateway` | `network` | `10.10.99.98` | `*.dcunha.io`                                 | LAN only (UCG-Max DNS)                | Internal-only services      |
| `edge-gateway`     | `network` | `10.10.99.90` | `*.frostlink.dev`, `*.dcunha.io`, `dcunha.io` | Public via towonel on frostlink + LAN | Every public service        |
| `external-gateway` | `network` | `10.10.99.97` | `*.dcunha.io`                                 | Nothing upstream                      | **Nothing** — no new routes |

All three gateways are in `kubernetes/apps/network/envoy-gateway/app/envoy.yaml`. `external-gateway` was the
Cloudflare-tunnel path. The team retired the tunnel (`06a0fe138`) after every public `*.dcunha.io` app
moved to `edge-gateway`. The gateway still exists and carries only the shared `https-redirect`.

Details of `edge-gateway`:

- It is a LoadBalancer on `10.10.99.90` with the LAN name `edge.dcunha.io`. `towonel-agent` dials `edge-gateway.network.svc.cluster.local:443`. LAN clients connect to the IP.
- It has three `:443` listeners: `https` (`frostlink-dev-tls`), `https-dcunha` (`*.dcunha.io`) and
  `https-dcunha-apex` (`dcunha.io`). The last two use `dcunha-io-tls`. The listener table and the
  `sectionName: https` trap are in `towonel-agent.md` § Which gateway to attach a route to.
- `SecurityPolicy/edge` sends every request to the CrowdSec bouncer (fail open). A route
  that adds its own SecurityPolicy needs `mergeType: StrategicMerge` to keep the bouncer check.
  See `crowdsec.md` § What is not covered.
- The `:80` listener `http` carries only the shared `https-redirect` route
  (301 to `https://`, path and query kept). It serves both paths. LAN clients connect to `10.10.99.90:80`.
  Public `http://` reaches it through towonel. The edge forwards plain HTTP by `Host` to the
  agent, and the agent always dials the origin host on **port 80**, whatever port `origin` names, with
  PROXY v2. towonel itself never redirects. Public `:80` needs TCP 80 open on the OCI
  security list of frostlink (frostlink `networking.md`). `https-redirect` carries
  `edge-dns.kubernetes.io/controller: none` so edge-dns ignores it.
- The per-client rate limit is on its own `BackendTrafficPolicy/edge`. It uses the Envoy
  local limiter, per client IP (`sourceCIDR` `Distinct`, the PROXY-protocol source), per route
  and **per Envoy pod**. With 2 replicas, the effective ceiling is about double the configured
  number. The rules are POSTs to known login paths
  (one regex) and a general per-IP cap. There is no Redis/Dragonfly and no rate-limit service, so nothing
  extra can fail. It is a separate policy and not part of `BackendTrafficPolicy/envoy`, because two
  gateway-level policies on one Gateway conflict. `envoy` now names `external-gateway` and
  `internal-gateway` explicitly, so the limit never applies to LAN-only apps. Route-level policies with
  `mergeType: StrategicMerge` (immich) inherit the limits. CrowdSec (above) provides smarter blocking.
- PROXY protocol: the setting lives on `ClientTrafficPolicy/edge` in `network`
  (`proxyProtocol.optional: true`), **not** on `EnvoyProxy/edge`. `EnvoyProxy/edge` carries only the
  LoadBalancer service type and the 2-replica deployment. Towonel sends the header. LAN clients do
  not, and `optional` accepts both. For the rationale and the failure signatures, see `towonel-agent.md`
  § PROXY protocol.
- Raw TCP goes through a ListenerSet. `spec.allowedListeners` admits the `external-endpoints` namespace.
  This is how Forgejo SSH lands on port 22 (§ Raw TCP ports on a shared gateway).
- The TCP and UDP services of towonel do not ride this gateway. They would go from the agent
  straight to the app Service. None are configured
  (`towonel-agent.md` § Beyond HTTPS).

Public or LAN picks the gateway. A public service (either domain) uses `edge-gateway`. A LAN-only service uses
`internal-gateway`. An app can carry two routes for two hostnames. `media/silo` has a
`route.app` (`silo.dcunha.io`) and a `route.jellyfin` (`jellyfin.dcunha.io` + `silo-jf.dcunha.io`,
a different port), both on `edge-gateway`. The towonel origin mapping lives in `.agents/references/towonel-agent.md`, which
wins over this file on anything towonel-specific.

Define routes **inline in helmrelease values** under `route.app:`. Do not use standalone
HTTPRoute files. A few routes predate the convention and still exist as files. Treat a new standalone file as a lint failure.
`grep -rl 'kind: HTTPRoute' kubernetes --include='*.yaml' | grep -v helmrelease` finds them. But
it also matches policy `targetRefs`, `components/` and the `external-endpoints` templates, so
read the hits.

### Gateway selection rules

**One route attaches to exactly one gateway.** Pick the gateway by exposure. For a public route, use:

```yaml
parentRefs:
    - name: edge-gateway # reachable from the internet via towonel on frostlink
      namespace: network
```

For a LAN-only route, use:

```yaml
parentRefs:
    - name: internal-gateway
      namespace: network
```

This applies to `external-endpoints` services (LXC, Proxmox, TrueNAS, Forgejo) exactly as it does
to k8s-native apps. There is no "use both" case. The rule itself is in
`instructions/cluster-conventions.md` (Common Mistakes, route gateway attachment), which wins. The
reasoning is here.

Never attach one route to both gateways. It is not a safety net. It is a silent failure:

- `external-dns-unifi` gets two CNAME targets and keeps **one**. It logs `ignoring additional
  CNAME targets; only the first target will be used`. The `parentRefs` order does **not** decide which target survives. `seerr` and `grafana` both listed `internal-gateway` first and still
  resolved to `external.dcunha.io`.
- It never converges. external-dns diffs the dropped target again and rewrites the UniFi zone on
  every 60s loop, indefinitely.
- The second parentRef bought nothing anyway, because the LAN already resolves the own gateway of a public route
  (next paragraph).

An external-only route still gets a LAN record. `external-dns-unifi` has no
`--gateway-name` filter, so it writes a CNAME for every route it sees, pointed at the target of the
gateway of that route. A public route on `edge-gateway` resolves to `edge.dcunha.io` →
`10.10.99.90` from the LAN. Traffic reaches the gateway directly and never hairpins out through
the VPS. So non-k8s services do not need a second gateway for LAN clients.

Two routes for one app are correct only across **different hostnames** (the jellyfin example
above). Never use one route with two parents.

The one legitimate dual-parent in the tree is `https-redirect` in
`kubernetes/apps/network/envoy-gateway/app/envoy.yaml`. It attaches to the `http` listener of
all three gateways (`edge-gateway`, `external-gateway`, `internal-gateway`), carries no hostnames,
and therefore generates no DNS record.

### Raw TCP ports on a shared gateway — ListenerSets

To put a non-HTTP port on an existing gateway, use a Gateway API `ListenerSet` (v1) plus a
`TCPRoute`/`UDPRoute`. Do not use a dedicated LoadBalancer IP. The gateway must opt in with
`spec.allowedListeners`. `edge-gateway` and `external-gateway` both allow ListenerSets only from
the `external-endpoints` namespace. Envoy Gateway then adds the port to the Service of the gateway.

Live example: Forgejo SSH. `external-endpoints/forgejo-ssh` is a ListenerSet with a TCP `ssh`
listener on 22, a `TCPRoute` to a headless `forgejo-ssh` Service, and an EndpointSlice that points at
the LXC (`10.10.99.24:22`). It parents `edge-gateway`, so `git.dcunha.io` answers HTTPS and SSH on
`.90`, and the `SSH_DOMAIN` of Forgejo is `git.dcunha.io`.

It stays **LAN/Headscale-only** by decision. towonel routes TLS by SNI, so SSH would
need a public TCP port on the VPS. The team considered that and rejected it because of scanner noise and the port
mismatch. PROXY protocol is optional on `edge-gateway`, so Envoy waits for the first
bytes of the client on this port. git works because SSH clients speak first, but `ssh-keyscan` can hang
(`towonel-agent.md` § PROXY protocol). Route `parentRefs` use `group: gateway.networking.k8s.io`,
`kind: ListenerSet`. Do not use the old `gateway.networking.x-k8s.io` group. Its `xlistenersets` CRD
(v1.4.1) is a leftover.

### Do not rename `compression` to `compressor` on Envoy Gateway 1.9.x

The CRD marks `BackendTrafficPolicy.spec.compression` as _"Deprecated: Use Compressor instead"_,
and the policy carries a `DeprecatedField` warning on every gateway. **Do not act on it on
1.9.x.** The CRD accepts `spec.compressor` and the status goes `Accepted=True`, so the change looks like a
clean fix. But on 1.9.0 the controller did not translate the field and **all compression silently
stopped** with no error. The CRD schema and the controller behavior are not the same version surface.
Verify with the live filter chain, not the policy status:

```bash
kubectl port-forward -n network <edge-gateway-or-internal-gateway-pod> 19000:19000
curl -s localhost:19000/config_dump |   jq -r '.configs[].dynamic_listeners[]?.active_state.listener.filter_chains[]?.filters[]?
         .typed_config.http_filters[]?.name' | sort -u
```

On 1.9.1, compression no longer stops. But `compressor` loses zstd and ignores list order
(`Accept-Encoding: zstd` alone gets nothing; `zstd, br, gzip` gets `br`). Test with
`curl -s -o /dev/null -D - -H "Accept-Encoding: zstd" https://<app>` against each gateway IP.
Check again on the next minor release. The deprecation warning is the lesser problem.

### Proxies roll all at once (`maxSurge: 100%`)

Both `EnvoyProxy` objects set `strategy.rollingUpdate` to `maxSurge: 100%, maxUnavailable: 0`. So
every proxy pod of a gateway is replaced in one step, and the old pods leave as soon as the new pods
are Ready. Proxies that still run when a new controller starts can lose their TLS certificates about
15 seconds later while they still report Ready (EG v1.9.1 release notes). A one-at-a-time rollout
stretches that window. The cluster has room for double the proxies.

The controller rolls the proxies itself about 20 seconds after it starts (the shutdown-manager
sidecar uses the controller image). So a manual `rollout restart` of the gateways only creates a
redundant second generation. The first pull of a new Envoy image (~55s per node) is the real length
of the mixed-version window.

### `envoy.enabled: false` does not disable Envoy

The Cilium Helm value picks **embedded-in-the-agent vs standalone DaemonSet**. It does not pick on or off.
With our `envoy.enabled: false`, `cilium-dbg status` reports `Envoy: embedded` and the L7
proxy runs (0 active redirects, because no L7 CiliumNetworkPolicies
or CiliumEnvoyConfigs exist for it to serve). The chart default is `true`, so we opt out of the
DaemonSet, not out of Envoy. The cost of embedded is that agent restarts disrupt live L7-proxied
traffic and Envoy shares the resource limits of the agent. With no redirects, that costs nothing today.

This is unrelated to `network/envoy-gateway`, which Cilium knows nothing about.

## Cluster-Internal Traffic

Pod-to-pod traffic uses `<app>.<namespace>.svc.cluster.local`, never an external hostname
(`AGENTS.md` rule 5 is the home for that rule, and it wins).

## VLANs

| VLAN | Name | Subnet          | IPv6                    | Purpose                                                    |
| ---- | ---- | --------------- | ----------------------- | ---------------------------------------------------------- |
| 1001 | HME  | 10.10.1.0/24    | none                    | Trusted home                                               |
| 1099 | LAB  | 10.10.99.0/24   | `2607:fea8:4e1f:3800::` | Servers, K8s nodes                                         |
| 1152 | IOT  | 10.10.152.0/24  | `2607:fea8:4e1f:3801::` | IoT (reachable from worker pods)                           |
| 1062 | CAM  | 10.10.62.0/24   | none                    | Cameras — frigate via the `cam` NAD                        |
| 1151 | GST  | 10.10.151.0/24  | none                    | Guest                                                      |
| 1088 | TST  | 192.168.88.0/24 | none                    | Testing                                                    |
| 1    | LAN  | 192.168.1.0/24  | none                    | Native/untagged on the UCG and CRS309 uplinks and pantheon |

Not a VLAN: WireGuard server `10.10.2.0/24` on the UCG (one peer, never connected). Wi-Fi: `SGxAP` → HME, `SGxGuest` → GST, `SGxIoT` → IOT.

DNS: the UCG-Max @ 10.10.99.1 serves LAN DNS. It answers the `*.dcunha.io` names that
external-dns-unifi writes into it and forwards everything else. It is not authoritative for the
zone. It also does WAN/NAT, VLANs, DHCP (the IPs of nodes, atlas and pantheon are DHCP reservations, not
static) and BGP (AS 64533). **Only the A record is overridden.** See § CoreDNS, Guard 2.

**The LAN-side AAAA leak.** external-dns-unifi writes the gateway names (`edge.dcunha.io`,
`internal.dcunha.io`, …) as IPv4-only dnsmasq `host-record`s, and it writes every app name as a `cname` to
one of them. dnsmasq answers the A record locally but **forwards the AAAA upstream**. So an IPv6-capable
LAN client gets whatever public DNS says for the gateway name
(`dig AAAA git.dcunha.io @10.10.99.1`).

The fix (`6086a4b2e`) is a public, grey
`edge.dcunha.io CNAME edge.frostlink.dev` in `kubernetes/apps/network/towonel-agent/app/dnsendpoint.yaml`
(external-dns-cloudflare reads it with its `crd` source). The forwarded AAAA then comes back NODATA, and the
client uses the local A. `internal.dcunha.io` has no public record and the wildcard is gone, so
its AAAA gets NXDOMAIN upstream and not a wrong address.

UniFi has no per-name "A only" option, and dnsmasq overwrites a hand edit. So the full fix
is still gateways with ULA IPv6 addresses and external-dns-unifi that publishes local AAAA. If
`edge.frostlink.dev` ever gains an AAAA, IPv6 LAN clients would start to hairpin through the VPS.

### Remote access — the UCG is the subnet router

The tailnet is self-hosted Headscale on Frostlink (`headscale.frostlink.dev`). The UCG Max is the
home subnet router, `tag:home-router`. It advertises LAB `10.10.99.0/24`, HME `10.10.1.0/24` and
the pod range of Artemis `10.42.0.0/16` (for ClusterMesh). Ansible manages it. See `ansible.md` § The UCG Max role. Away from home, a Headscale device with
subnet routes on reaches every LAB address and every `*.dcunha.io` gateway name, because the split
DNS of Headscale sends `dcunha.io` to `10.10.99.1`. This is how git SSH works remotely. Nothing is
port-forwarded. Public `dcunha.io` HTTPS now goes through towonel, but SSH does not
(§ Raw TCP ports on a shared gateway).

- The policy, split DNS and the device list live in the Frostlink repo, in its `headscale` app and
  its `networking.md` § Tailnet policy.
- arcana keeps subnet routes **off**. It already has HME and LAB NICs, and if it accepts the routes,
  Windows sends that LAN traffic through the tailnet.

### Firewall — traffic rules, not code

The UCG uses the legacy per-network firewall, managed as UniFi **traffic rules** (v2 API
`/proxy/network/v2/api/site/default/trafficrules`). The tofu provider models only the zone-based
firewall, so these rules exist only on the live system. Everything is open between networks except:

| Rule (description as shown in UniFi)                       | Effect                                                |
| ---------------------------------------------------------- | ----------------------------------------------------- |
| Block CAM VLAN from Internet / to Local Networks           | Cameras reach only frigate; NTP to Cloudflare allowed |
| Block GST VLAN to Local Networks (IoT allowed for casting) | Guest reaches the internet and IOT only               |

The guest rule deliberately omits IOT so guests can cast to TVs and speakers (the mDNS
reflector of UniFi handles discovery). It does not block the admin page of the gateway itself, because traffic rules
cannot target it. UniFi rejects the WireGuard network as a traffic-rule target
(`api.err.InvalidNetworkConfId`).

**The Mikrotik CRS309** is a plain downstream switch below the UCG. The UCG is
the router, DHCP/DNS server, STP root and mDNS reflector. The switch is managed at **`10.10.99.2`**
on LAB. It is a DHCP client with a UniFi fixed-IP reservation, and it gets its default route and DNS from the UCG. There
is no routed `/30` TRANSIT link (`172.16.99.x`) any more. The bridge, VLAN table, the two remaining VLAN
interfaces, route and DHCP client are in OpenTofu (`terraform/stacks/mikrotik`). The credentials are
`infrastructure/mikrotik-crs309`, and the SSH key of arcana is on `admin`.

Ports: `sfp-sfpplus1` → UCG, `sfp-sfpplus2` → 48-port UniFi switch (link down), `sfp-sfpplus7` →
atlas (1099 untagged), `sfp-sfpplus8` → pantheon, a **full trunk** as a hypervisor port must be
(VLAN 1 untagged, and 1001, 1062, 1088, 1099, 1151, 1152 tagged).

**LLDP stops at the CRS309, so the UniFi topology cannot show what is behind it.** Every lab host
advertises itself. pantheon uses the ansible role `lldpd`. atlas uses a `truenas_app` in the tofu
`truenas` stack (TrueNAS 25.10 has no LLDP service and a read-only `/usr`). Every Talos node
uses the `lldpd` DaemonSet in `kube-system`. The CRS309 lists pantheon, atlas and the three
pantheon VMs (`/ip neighbor print`, because `group_fwd_mask` of vmbr0 passes LLDP through). The US48 lists
ymir and the control-plane nodes. UniFi draws the topology only from the LLDP tables of its own devices,
and port 3 of the UCG sees just the CRS309. So everything behind it appears as a client on UCG
port 3, not under the switch.

**It is not L2-only for IPv6, and the IOT interface must stay.** It owns `fd00:10:10:152::1` on IOT
and advertises the ULA prefix there (RA with `ra-lifetime=none`, so it is not a default router).
That ULA is what the static addresses of the `iot` NAD and the Thread/Matter devices use. The UCG
cannot also hand out a ULA. An earlier RA with a router lifetime is what broke Matter.

IPv6 prefixes come from Rogers DHCPv6-PD on the UCG WAN and **rotate**. Never hardcode a GUA
from them. VLAN 1152 also carries the legacy ULA `fd00:10:10:152::/64`. The Mikrotik still advertises it, and the static addresses of the `iot` NAD still use it.

### endpointRoutes is off — and turning a Cilium flag off is not symmetric

`endpointRoutes.enabled` is off. netkit, native routing, BPF masquerade and
`socketLB.hostNamespaceOnly` do not require it. The combination with netkit and `socketLB.hostNamespaceOnly`
misclassifies service replies as `CT_NEW`
([cilium#47913](https://github.com/cilium/cilium/issues/47913)). Two traps made "I turned it off"
a false statement, and both apply to any Cilium flag:

1. Removing the value does not remove the setting. The chart emits the key **only when
   true**. So if you set `false`, the chart omits the key, and Helm leaves the previous `enable-endpoint-routes: "true"`
   orphaned in `cilium-config`. `Helm upgrade succeeded` while the setting stayed on. The fix is
   `kubectl patch cm -n kube-system cilium-config --type=json -p '[{"op":"remove","path":"/data/enable-endpoint-routes"}]'`
   followed by an agent roll. Verify the ConfigMap and the startup log of the agent
   (`--enable-endpoint-routes='false'`), never the Helm status.
2. Existing pods keep the old delivery path. Cilium cannot rewrite a live endpoint, so
   per-endpoint `/32` routes to `lxc*` devices persist until each pod is recreated. Both paths
   work concurrently. The same asymmetry applies to `enableIPv4BIGTCP`.

`rollOutCiliumPods: false`, so the agent roll is manual. Do it one node at a time. Do not
let `maxUnavailable: 2` take two control planes.

Counting gotcha: `cilium-dbg metrics list | grep 'Policy denied'` returns _two_ rows,
`cilium_drop_bytes_total` and `cilium_drop_count_total`. Read the count, not the bytes.

### Cilium's VLAN filter and the drop counter

`devices: bond+` attaches Cilium to the parent trunk `bond0` as well as its sub-interfaces. So the
host firewall runs on raw tagged frames and drops every tag that Cilium does not manage. Tags that have
a managed device (**1099, 1152, 1062**) are auto-allowed. Cilium counts the rest as
`cilium_drop_count_total{reason="VLAN traffic disallowed by VLAN filter"}`.

`bpf.vlanBypass: [1001, 1151, 1088]` allows the three trunked VLANs that have no node
interface. Upstream caps the list at **5 entries**. `[0]` means allow-all and disables the filter
entirely.

It only halves the counter. Every VLAN in the table above is either managed or bypassed, so
the residual is something else. The most likely cause is priority-tagged frames (VLAN ID 0). You cannot list them individually, because `0` is
the allow-all sentinel. The team left it as is. The drops are benign (the host would discard those frames
anyway), and disabling the filter wholesale is not worth a cleaner graph.

For alerting, exclude that `reason` label. Do not alert on total drops.

The agent scans for VLAN devices **only at startup**. If you add a VLAN sub-interface to the nodes,
Cilium silently filters its traffic until the Cilium agents restart.

## Dual-stack (since 2026-09-24)

Pods get IPv6 as well as IPv4. IPv4 stays the primary family. Services stay IPv4-only unless one
opts in with `PreferDualStack`/`RequireDualStack`.

| Range                   | What                                                                         |
| ----------------------- | ---------------------------------------------------------------------------- |
| `fd00:10:10:99::<N>/64` | Node address on `bond0.1099`, `N` = last IPv4 octet. The kubelet node IP     |
| `fd00:42:1:<n>::/64`    | Per-node pod range via the `network.cilium.io/ipv6-pod-cidr` node annotation |
| `fd00:42::/56`          | kcm's pod range — only a node registered after 2026-09-24 draws from it      |
| `fd00:43::/108`         | Service range. The default ServiceCIDR is now dual and **cannot go back**    |
| `fd00:42::/32`          | Cilium `ipv6NativeRoutingCIDR` — must cover both pod ranges above            |

- Why an annotation and not `spec.podCIDRs`: the podCIDRs of a Node can only go from empty to set, so
  existing nodes never gain a v6 range from kcm. Cilium reads the annotation because
  `annotateK8sNode: true`. `spec.podCIDRs` wins if both exist. The annotation lives in each
  `talos/nodes/<node>.yaml.j2`, so drop it when a node is rebuilt and gets a kcm range.
  `n` is the third octet of the IPv4 podCIDR of the node.
- Why `/32` and not `/48`: `fd00:42::/48` does not contain `fd00:42:1::`, because the third hextet is
  outside it.
- Egress: pod IPv6 is BPF-masqueraded to the Rogers GUA of the node on `bond0.1099`, which rotates.
  The node ULA is never an egress source, because nothing upstream routes `fd00::/8`.
- Cilium does not retrofit running pods. A pod created before the Cilium agent of its node
  restarted has no IPv6 until it restarts. The check below counts the stragglers.
- CoreDNS Guard 2 still answers NODATA for every AAAA. One condition blocked narrowing
  it back to `dcunha.io`: a pod without IPv6 that gets a real AAAA fails with
  `network is unreachable`. That condition is **met**, because no running pod lacks IPv6. The manifest is unchanged (`template ANY AAAA .`). The narrowing is
  tracked in [#2364](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2364).
  Before you narrow it, check again with `kubectl get pods -A -o json | jq '[.items[] | select(.spec.hostNetwork != true and .status.phase == "Running" and (.status.podIPs | length) < 2)] | length'`.
- IPv6 LoadBalancer IPs over BGP are not done. Cilium sends an IPv4 next hop for IPv6
  routes on the existing sessions, and the UCG has no stable IPv6 to peer with.

### IoT pods drop the Cilium IPv6 default route

With Cilium IPv6 on, a pod on the `iot` NAD gets two IPv6 defaults at the same metric. One is the default of Cilium on
`eth0` and the other is the RA of the UCG on `net1`. The kernel **merges them into one ECMP route**. Thread
traffic (`fdf4:6f68:f055:1::/64`, reached only through the default; see _Thread routing rides the
default route_) is then hashed across both, and the `eth0` half is masqueraded out of the node.

`home-assistant` and `matter-server` carry an `iot-v6-route` init container. It waits for the
`net1` RA default, then deletes only the `eth0` nexthop. Everything else about the pod is
unchanged. The RA stays the source of the default, and cluster IPv6 on `eth0` still works through
its connected routes.

- Delete by `via <gw> dev eth0`, never by `dev eth0` alone. If the RA default is already merged, Busybox `ip` removes the whole
  multipath route, and `net1` has no default until
  the next RA.
- It works under `hostUsers: false` (matter-server). The netns of the pod belongs to the user
  namespace of the pod, so `NET_ADMIN` in the init container is enough.
- homebridge, esphome and victoria-logs do not have the init container. They reach IoT devices through the
  on-link `fd00:10:10:152::/64`, which is more specific than either default, and they do not talk to
  the Thread mesh. Add the init container to any new pod that does.

## External DNS

External-dns instances run in `network`. Each instance is pinned to one zone and one provider:

| Deployment                | Zone            | Provider   | Sources                        | `txt-owner-id`    | `txt-prefix`                   |
| ------------------------- | --------------- | ---------- | ------------------------------ | ----------------- | ------------------------------ |
| `external-dns-unifi`      | `dcunha.io`     | webhook    | `gateway-httproute`, `service` | `k8s-internal`    | `k8s.internal.%{record_type}-` |
| `external-dns-cloudflare` | `dcunha.io`     | Cloudflare | `gateway-httproute`, `crd`     | `artemis-cluster` | `k8s.%{record_type}-`          |
| `external-dns-edge`       | `dcunha.io`     | Cloudflare | `gateway-httproute`            | `artemis-edge`    | `k8s.edge.%{record_type}-`     |
| `external-dns-frostlink`  | `frostlink.dev` | Cloudflare | `crd` **only**                 | `artemis`         | `k8s.artemis.%{record_type}-`  |

- `external-dns-unifi` writes to the UCG-Max and is what makes `*.dcunha.io` resolve on the LAN.
  It has **no `--gateway-name` filter**, so it watches every HTTPRoute on every gateway. This is
  why two routes that share one hostname race to own the internal A record.
- `external-dns-cloudflare` is filtered to `--gateway-name=external-gateway` and runs
  `--cloudflare-proxied`. The tunnel is retired and no routes are left on `external-gateway`, so its
  `gateway-httproute` source publishes nothing. What it still owns comes from its `crd` source:
  the orange `status.dcunha.io` (cloudflare-dns DNSEndpoint) and the grey `edge.dcunha.io`
  (towonel-agent DNSEndpoint, `cloudflare-proxied: "false"` per endpoint).
- `external-dns-edge` (app `network/edge-dns`) publishes grey CNAMEs → `edge.frostlink.dev` for
  every `edge-gateway` route. It reads only `edge-dns.kubernetes.io/`-prefixed annotations, so the
  standard `external-dns.kubernetes.io/target` of the gateway stays for `external-dns-unifi` (LAN).
  Details: `towonel-agent.md` § The dcunha.io zone.
- `external-dns-frostlink` serves the zone of the other cluster. Its owner id and prefix **must** differ
  from the own instance of frostlink. If they do not, the two instances delete each other's records in a loop.
  `towonel-agent.md` § The collision guard is the authority on that. Do not restate it here.

All of them run `--policy=sync`. They delete anything that they believe they own and no longer see.

## CoreDNS

Manifest: `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml`. It is the upstream
coredns chart with the home-operations plugin chain. The two `template` plugins between
`autopath` and `forward` are ours and are load-bearing. Their rationale lives here, not in
the manifest.

### Plugin order is load-bearing

```text
kubernetes → autopath → template(ANY ANY dcunha.io) → template(ANY AAAA dcunha.io) → forward
```

Both templates must stay **after** `kubernetes` and in **this relative order**. If you change
either position, you bring back the cluster-wide outage described below.

### Guard 1 — `template ANY ANY dcunha.io`, NXDOMAIN for 2+ label names

Talos 1.14 applies the DHCPv4 search domain, so the `resolv.conf` of every pod now ends with
`dcunha.io`. With `ndots:5`, a name like `postgres-rw.database.svc.cluster.local` (4 dots)
walks the search list before the resolver tries it as an absolute name. `<anything>.dcunha.io` resolves through
a Cloudflare wildcard, so upstream answered `172.64.80.1` instead of the ClusterIP. glibc
callers (immich, paperless, zigbee, forgesync…) broke. busybox/musl was unaffected because
it tries the absolute name first.

The problem is not limited to cluster names. `ghcr.io` (1 dot, also under `ndots:5`) becomes
`ghcr.io.dcunha.io`, which the wildcard answers, and TLS then fails on the cert mismatch.
That took out every OCIRepository at once. The bug class is "a name that already contains a
dot got the search domain appended". So the guard answers NXDOMAIN to anything with 2+ labels ahead of
`dcunha.io`. Real hosts here are single-label (`git`/`id`/`artemis`.dcunha.io) and keep
resolving normally.

The answer must be NXDOMAIN specifically. A NODATA would let the search-domain walk continue.

The team deleted the Cloudflare wildcard that made this bite on 2026-10-04 with the tunnel, so upstream
now answers these names NXDOMAIN by itself. The guard is still in place.

### Guard 2 — `template ANY AAAA dcunha.io`, NODATA for AAAA

Internal split-horizon overrides only the A record, so a public AAAA passes through untouched.
The pod network cannot reach that address, and any client that tries it first dies with
"network is unreachable". This happens intermittently, across unrelated tasks and hosts. NODATA (NOERROR, no answer, no fallthrough)
means that callers only ever see the reachable IPv4. The `authority` SOA lets resolvers
negative-cache the NODATA and not ask again on every lookup.

The guard still covers any name that has a public AAAA.

### Guard 2 is unscoped — `template ANY AAAA .`

Guard 2 matches `.`, which is every zone and not just `dcunha.io`. The cluster has no
usable IPv6 for ordinary pods, so NODATA is the truthful answer to any AAAA. This stops
clients from dialling addresses that can only fail.

Two constraints hold it in place:

- Its position is still load-bearing. It must stay **after** Guard 1. If it comes first, it would
  answer AAAA for `ghcr.io.dcunha.io` with NODATA before Guard 1 could return NXDOMAIN,
  and that breaks the search-domain hijack fix again.
- It intercepts `cluster.local` AAAA too, because `template` precedes `kubernetes` in
  the plugin chain of CoreDNS. Services default to IPv4-only, so NODATA is correct for them. A
  Service that opts into dual-stack loses its AAAA to this guard. List them with
  `kubectl get svc -A -o json | jq -r '.items[] | select(.spec.ipFamilyPolicy != "SingleStack") | "\(.metadata.namespace)/\(.metadata.name)"'`.
  The cluster is dual-stacked now, so this is the first thing to revert when you narrow Guard 2.

This guard is a workaround for pods that have no IPv6. The cluster is dual-stacked now, and the
condition that _Dual-stack_ set for narrowing it is met. The narrowing is
[#2364](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2364). Nothing about Matter blocks it.
See _CoreDNS plays no part in Matter_.

### Verifying a CoreDNS change

Validate offline before you touch cluster DNS, because a bad Corefile crashloops every DNS pod. The
chart does **not** run `configBlock` through `tpl` (`{{ .configBlock | indent 12 }}`). So Go
template vars like `{{ .Zone }}` reach the Corefile literally, and CoreDNS expands them at
query time. Flux `postBuild` uses `${...}` and does not touch them either.

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
| `AAAA ghcr.io`           | NOERROR, 0 answers |
| `A git.dcunha.io`        | 10.10.99.90        |
| `AAAA git.dcunha.io`     | NOERROR, 0 answers |
| `A ghcr.io.dcunha.io`    | NXDOMAIN           |
| `AAAA ghcr.io.dcunha.io` | NXDOMAIN           |

Confirm live from a **glibc** pod (`kubectl exec -n database postgres-1 -c postgres`). musl
images resolve differently and hide the original bug class.

## BGP / Control-Plane Endpoint

The UCG-Max runs FRRouting (`vtysh -c "show version"`), and you can `ssh root@10.10.99.1` to
inspect it (`vtysh -c "show bgp ipv4 unicast summary"`, `ip route show <ip>`):

| Item                | Value                                                          |
| ------------------- | -------------------------------------------------------------- |
| UCG ASN / router-id | `64533` / `10.10.99.1`                                         |
| Cluster ASN         | `64512` (Cilium, `CiliumBGPClusterConfig`)                     |
| Peers               | eBGP, one neighbour line per node, description = node hostname |
| Hold / keepalive    | `9s` / `3s`                                                    |

### Editing the BGP config — it is not a file on disk

`/etc/frr/frr.conf` on the UCG holds only stock defaults (`log syslog informational`) and
nothing else. The real config lives in the **MongoDB of the UniFi controller**
(`/data/unifi/data/db/ace`), and the controller pushes it into FRR. Nothing renders it to
disk, so if you `grep` the filesystem for a neighbor address, you find only DNS leases and logs.

There is no form-based BGP UI. The config is a **raw FRR file that you upload** in the Network app
under **Settings → Routing → BGP**. It contains just the `router bgp` block. The controller
generates the surrounding `frr version` / `hostname` / `domainname` lines itself.

A `vtysh -c "configure terminal" -c "router bgp 64533" -c "neighbor ..."` change applies
immediately and survives an FRR restart, but the controller **overwrites it on the next
provision**. Use vtysh only to get a peer up in the moment. The upload is the durable edit.

To add a node, add two neighbor lines plus one line in `address-family ipv4 unicast`:

```
 neighbor 10.10.99.204 remote-as 64512
 neighbor 10.10.99.204 description ymir
 !
 address-family ipv4 unicast
  neighbor 10.10.99.204 soft-reconfiguration inbound
 exit-address-family
```

Cilium needs no matching change. `CiliumBGPClusterConfig` selects on
`kubernetes.io/os: linux`, so every node is already a speaker, and the session establishes as
soon as the neighbor exists on the UCG. To dump the current config for re-upload, run:
`ssh root@10.10.99.1 'vtysh -c "show running-config"' | sed -n '/^router bgp/,/^exit$/p'`

**A node joins the cluster with its BGP session already broken, and nothing surfaces it.** The
node goes `Ready` and workloads schedule. The only symptom is that no `externalTrafficPolicy:
Local` LoadBalancer whose pod lands there is reachable. Cilium reports the truth, but only if you
ask for it:

```bash
kubectl get ciliumbgpnodeconfig -o json \
  | jq -r '.items[] | "\(.metadata.name): \(.status.bgpInstances[].peers[].peeringState)"'
```

This hit `ymir`, which sat `idle` until the team uploaded its `10.10.99.204` neighbour lines. After you add any node, add the
lines and run the command above again before you consider the node done.

`artemis.dcunha.io` → `10.10.99.99` is a **Cilium LoadBalancer Service** (`kube-api` in
`kube-system`) that selects apiserver pods with `externalTrafficPolicy: Local`, advertised over
BGP. **ECMP already works.** The UCG shows 3 `multipath` paths and 3 kernel next-hops, one
per control plane. The FRR config has no `maximum-paths` line, and none is needed.

BGP negotiates the **minimum** hold time of the two peers, so the cluster-side timers win. The UCG
offers 180/60 and Cilium proposes 9/3. Do not "fix" this on the router. Before 9/3 the hold time was 90s,
which meant that a hard control-plane failure (power loss, not a graceful withdrawal) black-holed
roughly a third of API traffic for up to 90 seconds.

### Graceful restart — why `restartTimeSeconds: 30` sits next to a 9s hold time

The UCG already runs as a GR helper (FRR 10.1.2, `Local GR Mode: Helper`), but Cilium never
advertised the capability, so the session showed `Remote GR Mode: Disable`. Every session drop
therefore withdrew every VIP at once and took `internal-gateway` (10.10.99.98) out along with
everything else. `gracefulRestart` in
`CiliumBGPPeerConfig/l3-bgp-peer-config` makes the UCG hold the routes as stale and keep
forwarding through a flap.

30s is deliberate, and it is a trade against the 9s hold time above. Spurious flaps
re-establish in 1–3s and are fully covered. A genuinely dead node now black-holes for up
to 30s and not 9s. BFD would avoid the trade, but the UCG ships no `bfdd` binary, so it is
not an option.

### ClusterMesh with Frostlink

Artemis is meshed with Frostlink. The design, the shared CA, the Headscale grants and the traps
are canonical in `clustermesh.md` in the references of the Frostlink repo. Read that first. What
is specific to this side:

- BGP advertises `PodCIDR` as well as `LoadBalancerIP` (`kube-system/cilium/app/network.yaml`),
  so the UCG holds one `/24` per node and can route Frostlink → Artemis pods.
- ip-masq-agent (`nonMasqueradeCIDRs: [10.42.0.0/16, 10.244.0.0/24]`, `masqLinkLocal: true`)
  keeps pod → LAN traffic masqueraded to the node IP exactly as before, while pod → Frostlink pod
  keeps its source. Do **not** widen `ipv4NativeRoutingCIDR` instead. Cilium checks the native CIDR
  before ip-masq-agent, so a wider CIDR would stop masquerading pod → LAN traffic. That breaks because the
  LAN hosts reply through the UCG.
- The mesh endpoint is LoadBalancer `10.10.99.93:2379` (`lbipam.cilium.io/ips`), with
  `service.cilium.io/forwarding-mode: snat` because the cluster default is DSR.
- `directRoutingSkipUnreachable: true`, because the Frostlink node is not on the LAN, so
  `autoDirectNodeRoutes` must skip it and not error.
- `bpf.lbModeAnnotation: true` lets an externally exposed global service opt out of DSR, which
  cannot return traffic from a Frostlink backend.

### Declined: anycast control-plane endpoint via Talos native BGP

Do not re-open this without new information. Cilium cannot advertise `10.10.99.99` unless the API
server is already up. So the endpoint is unavailable during a cold start or a total Cilium outage,
and workers (pointed at `https://artemis.dcunha.io:6443`) cannot join while it is down. Talos 1.14
native BGP runs without Kubernetes and could close that gap, but:

- Talos and Cilium sessions to one UCG neighbour collide. `BGPPeerConfig` has no source-address
  field, both source from `bond0.1099`, and BGP collision resolution tears one down. Unnumbered
  peering does not fix it for IPv4 (Talos has no RFC 5549 support).
- To close the gap, you need either a new peering VLAN, or a BGP split by role so that control planes run
  only the Talos session. The split leaves any `externalTrafficPolicy: Local` LoadBalancer whose
  pod lands on a control plane silently unreachable, which is a standing scheduling constraint.
- ECMP already works and hold timers are 9s, so steady-state failover is fine. The change is not worth the cost.

`etp: Local` is load-bearing for more than scheduling. Cilium runs `loadBalancer.mode: dsr`
with the default `opt` dispatch, which encodes the original address in a Cilium-specific IPv4
option. Upstream warns that routers can punt or drop such packets. It is safe for north-south
traffic only because `etp: Local` means it never needs the remote-backend forwarding path that DSR
exists for. A LoadBalancer created with the Kubernetes default (`etp: Cluster`) would send
IP-option packets across the UCG-Max, and that shows up as intermittent, load-dependent loss on one
service. Set `etp: Local` on every north-south LoadBalancer, or change the dispatch mode first.
The one `etp: Cluster` LoadBalancer is `kube-system/clustermesh-apiserver`, which is why it
carries `service.cilium.io/forwarding-mode: snat`. List them with
`kubectl get svc -A --field-selector spec.type=LoadBalancer -o custom-columns=NS:.metadata.namespace,N:.metadata.name,ETP:.spec.externalTrafficPolicy`.

Gateway replicas are not pinned, so the nodes they land on change with every reschedule
(`kubectl get pods -n network -o wide -l gateway.envoyproxy.io/owning-gateway-name`).

## Multus — IoT VLAN Attachment

Pods that need direct L2 access to IoT VLAN 1152 (for example home-automation apps and Matter Server) get a
secondary `net1` interface through Multus. The network attachment definition is named `iot` in `kube-system`.
A second NAD, `cam` in `kube-system`, puts frigate on the camera VLAN 1062. Frigate runs on
ymir. Since 2026-09-23 the CRS309 also trunks 1062 to pantheon, so a pantheon VM can host it too.

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

- IPv4: `10.10.152.<N>/24`. Pick the next available address in the static range.
- IPv6: `fd00:10:10:152::<N>/64`. It always matches the IPv4 last octet (`<N>` in decimal, no conversion needed for values ≤ 255).
- MAC: static and manually assigned. Use the `02:` prefix (locally administered unicast). Keep it unique across all pods.
- Gateway (IPv4): `10.10.152.1` (UCG-Max IoT VLAN interface)
- IPv6 default route: learned through RA from the UCG-Max (`fd00:10:10:152::1`)

### Assigned addresses

| App            | IPv4            | IPv6                  | MAC               |
| -------------- | --------------- | --------------------- | ----------------- |
| home-assistant | 10.10.152.10/24 | fd00:10:10:152::10/64 | 02:4d:60:06:55:be |
| matter-server  | 10.10.152.11/24 | fd00:10:10:152::11/64 | 02:0c:d8:a2:91:8f |
| homebridge     | 10.10.152.12/24 | fd00:10:10:152::12/64 | 02:ee:bb:51:b4:dc |
| esphome        | 10.10.152.13/24 | fd00:10:10:152::13/64 | 02:4d:60:0e:5e:0d |
| victoria-logs  | 10.10.152.14/24 | fd00:10:10:152::14/64 | 02:1a:c3:7f:9e:44 |
| bambuddy       | 10.10.152.15/24 | fd00:10:10:152::15/64 | 02:a5:d2:b4:e5:40 |

Next available: `.16` / `::16`

### Thread / Matter context

The IoT VLAN hosts the Thread mesh through three border routers:

| Device            | IP            | MAC               | Link-local IPv6           | TBR policy  |
| ----------------- | ------------- | ----------------- | ------------------------- | ----------- |
| Apple TV Basement | 10.10.152.166 | 48:e1:5c:76:22:2b | fe80::4ae1:5cff:fe76:222b | Restrictive |
| Nest Hub #EB53    | 10.10.152.86  | 38:86:f7:0e:96:93 | fe80::3a86:f7ff:fe0e:9693 | Open        |
| Nest Hub #2960    | 10.10.152.99  | d8:eb:46:d6:b9:4c | fe80::daeb:46ff:fed6:b94c | Open        |

Thread network: `NEST-PAN-0751`, Channel 22, Extended PAN ID `7fd8ca45c6794b90`

Apple TV blocks third-party Matter commissioning through Thread. Route through a Nest Hub instead.

### Thread routing rides the default route — do not remove it

The Thread mesh prefix (`fdf4:6f68:f055:1::/64`) is not RA-learned as a specific route. `net1`
carries `accept_ra_rt_info_max_plen=0`, so the kernel **ignores** the RFC 4191 route-information options
of the border routers. Matter reaches Thread devices through the IPv6 **default route** of the pod, which makes
`::/0` on `net1` load-bearing for the Matter fabric.

That default does not come from the NAD. The `iot` NAD declares `{"dst": "::/0", "gw": "fe80::58d6:1fff:fe27:c2e3"}`,
but `sbr` never applies it. `sbr` copies a route into the sbr table only when the address
prefix of the pod contains the gateway, and `fd00:10:10:152::/64` does not contain a link-local. The only
IPv6 default is in `main`, `via fe80::58d6:1fff:fe27:c2e3 dev net1 metric 1024 expires 0sec`. It is a
**Router Advertisement**, not a CNI route. So the `::/0` line of the NAD is decorative (leave it alone,
because removing it is a live change to a Matter-carrying NAD for no gain). No CNI-installed
fallback exists behind the RA, so the trap below is real.

### The `sbr` link-local trap — read before changing RA on VLAN 1152

The `iot` NAD chains the `sbr` (source-based routing) plugin. The plugin creates
`ip -6 rule: from fd00:10:10:152::10 lookup 101` and places `fe80::/64 dev net1` in **table 101
only**. Matter uses the _link-local_ address of net1 as source when it talks to link-local peers. That address does
not match the rule, so the traffic falls through to `main`. There, the RA-learned default route is the only
net1 entry that catches it.

The consequence: **removing the last IPv6 default router from VLAN 1152 breaks Matter**, even
though nothing about the change looks DNS- or Matter-related. The symptom is
`send ENETUNREACH fe80::...%net1:5540` and devices that cycle offline.

If this comes up again, follow this safe sequence:

1. Make sure that another router already advertises a default on the VLAN. Verify with
   `kubectl exec -n home-automation deploy/home-assistant -c app -- ip -6 route show | grep default`
2. Demote first (`ra-preference=low`), verify that clients moved, and only then set `ra-lifetime=0s`
3. To drop the default route from the **Talos hosts** without touching pods, use the sysctl
   `net.ipv6.conf.bond0/1152.accept_ra_defrtr=0`. macvlan children have their own netns and
   `accept_ra`, so it cannot affect the Matter pods

### CoreDNS plays no part in Matter

Matter/Thread discovery is mDNS over multicast (`ff02::fb`) that uses the own resolver of the CHIP stack,
and the pods run `hosts: files dns` with no mDNS NSS module. The
`fd00:10:10:152::/64` and Thread ULA ranges have no unicast DNS records in either direction.
So CoreDNS changes cannot affect the Matter fabric, and Guard 2 does not need to stay scoped for it.

`fc00::/7` covers all ULA addresses, including any Thread mesh prefix. The more specific
`fd00:10:10:152::/64` (IoT VLAN) takes precedence automatically. Only Thread ULA traffic goes through the TBR.
