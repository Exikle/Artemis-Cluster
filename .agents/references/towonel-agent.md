# towonel Agent — Artemis-Cluster

This file explains how Artemis services are published through the towonel tunnel that runs on frostlink.

**Shape 1, from the frostlink front-door refactor (Artemis #3082).** Public traffic is no longer passed
through to Artemis. frostlink's Envoy terminates TLS for every public hostname and runs CrowdSec. It
then re-encrypts to Artemis over one towonel TCP service: `artemis-backhaul`, edge port 15001, origin
`edge-gateway.network.svc.cluster.local:443`. The agent claims no hostnames. `edge-gateway` is still the
list of public Artemis apps: frostlink routes all of `*.dcunha.io` to it. The sections below on SNI
passthrough, hostname claims, PROXY protocol and the `*.frostlink.dev` wildcard describe the
retired design. They need a rewrite.

The agent is deployed and operational. `kubernetes/apps/network/towonel-agent/` holds a `HelmRelease` (its
ExternalSecret is inline under `externalSecrets:`), a `DNSEndpoint` and an `OCIRepository`. `edge-gateway`
carries every public route on Artemis, `*.frostlink.dev` and `*.dcunha.io` alike. The Artemis
Cloudflare tunnel is retired (§ The dcunha.io zone).

Upstream: <https://codeberg.org/towonel/towonel>. The agent is deployed here as app-template
(`oci://ghcr.io/bjw-s-labs/helm/app-template`) that runs the
`codeberg.org/towonel/towonel-agent` image. It is not the upstream `towonel-agent` chart. To see both
versions, run `grep -h 'tag:' kubernetes/apps/network/towonel-agent/app/*.yaml`. This follows
bjw-s-labs/home-ops and keeps the app on the one-OCIRepository-per-app convention of this repo. The configuration is therefore
environment variables (`TOWONEL_AGENT_*`), not chart values.

## What it is, and why Artemis wants it

frostlink is the public Oracle Cloud VPS. It lives in a separate repo and runs the towonel hub and
edge. An agent here dials out over iroh QUIC and holds the connection open.
Artemis therefore publishes public hostnames without opening a single inbound port.

The edge peeks at the SNI and forwards the raw TLS stream to the agent. The agent hands
the stream to a local origin. Nothing in the middle terminates TLS.

Repo boundary: frostlink and Artemis stay separate repos. The entire interface
is one invite token and a hostname. Do not share manifests or components. Do not
propose a monorepo.

## The design that worked

Point the agent at the own gateway of this cluster, with one wildcard entry per domain:

```yaml
TOWONEL_AGENT_SERVICES: |
    [{"hostname":"*.frostlink.dev","origin":"edge-gateway.network.svc.cluster.local:443"},
     {"hostname":"*.dcunha.io","origin":"edge-gateway.network.svc.cluster.local:443"},
     {"hostname":"dcunha.io","origin":"edge-gateway.network.svc.cluster.local:443"}]
```

Two things follow:

1. To publish more hostnames under either domain, add a normal HTTPRoute on
   `edge-gateway`. Only a new _domain_ touches towonel. A new domain needs an entry here and an entry on the
   hub invite (§ Getting an invite token).
2. The `frostlink.dev` certificate belongs to frostlink and Artemis imports it through 1Password. Artemis no
   longer issues its own. See § The certificate, and the key note below for why a second
   key buys no protection. `dcunha.io` uses the own `dcunha-io-tls` of Artemis.

Service names here are literally the Gateway names (`edge-gateway`, `external-gateway`).
envoy-gateway does not apply its `envoy-<ns>-<gw>-<hash>` naming in this cluster.

### Which gateway to attach a route to

This split exists to make routing simple. This table is the only rule you need:

| Hostname                | `parentRefs`       | `sectionName`           | Path                      |
| ----------------------- | ------------------ | ----------------------- | ------------------------- |
| `*.frostlink.dev`       | `edge-gateway`     | `https`, or none        | towonel (public, via VPS) |
| `*.dcunha.io`, public   | `edge-gateway`     | `https-dcunha`, or none | towonel (public, via VPS) |
| `dcunha.io` apex        | `edge-gateway`     | `https-dcunha-apex`     | towonel (public, via VPS) |
| `*.dcunha.io`, LAN only | `internal-gateway` | `https`, or none        | LAN only                  |

`external-gateway` takes no new routes. It still exists (`10.10.99.97`), but it carries nothing
except the shared `https-redirect`. Its only upstream, the Cloudflare tunnel, is gone.

`edge-gateway` is a LoadBalancer on `10.10.99.90` (LAN name `edge.dcunha.io`). It has three `:443` listeners:
`https` (no hostname, `frostlink-dev-tls`), `https-dcunha` (`*.dcunha.io`, `dcunha-io-tls`) and
`https-dcunha-apex` (`dcunha.io`, same cert). The wildcard listener does not match the apex.
Public traffic reaches the gateway through towonel. LAN clients connect to `10.10.99.90` directly.

The `sectionName: https` trap: on `internal-gateway` and `external-gateway`, `https` is the
`dcunha.io` listener. On `edge-gateway` it is the `frostlink.dev` listener, so a `*.dcunha.io` route
that pins `sectionName: https` never attaches. If you move a route from `external-gateway`, change
the parentRef and change any `sectionName: https` to `https-dcunha`. Auth SecurityPolicies
(tinyauth, envoy-oidc) target the HTTPRoute, not the gateway, so they follow the route unchanged.

Withholding the key of frostlink from Artemis protects nothing. frostlink already holds a
publicly trusted `*.frostlink.dev` private key on its own cluster (it exports the key to 1Password).
Suppose the VPS of frostlink is compromised. The attacker then controls the edge _and_ already has a valid
wildcard key for those names, so the attacker can terminate TLS and MITM Artemis-bound traffic.
Withholding a second key does not prevent that. Separation would buy only independent rotation
and fewer copies of a key in flight.

## The certificate

`frostlink-dev-tls` in `network` is imported from 1Password. It is not issued here. frostlink
issues the certificate and pushes it, and Artemis pulls it. It covers `frostlink.dev` and
`*.frostlink.dev`, so it is strictly better than the wildcard-only cert that Artemis used to
issue for itself.

The import must refresh. Copy the shape from
`certificates/import/frostlink-externalsecret.yaml`, _not_ from the neighboring
`externalsecret.yaml`. The frostlink import sets no `refreshPolicy`, so it keeps the ExternalSecret
defaults: `refreshInterval` 1h and `creationPolicy: Owner`. The dcunha import is deliberately
bootstrap-only (`refreshPolicy: CreatedOnce`, `creationPolicy: Orphan`). It seeds the secret
once, and then cert-manager owns the renewal. If you copy that pattern here, Artemis pulls the cert once and
never picks up a renewal. Artemis would then silently serve an expired certificate at the
next rollover of frostlink.

Both values are base64-encoded in the 1Password item, hence `decodingStrategy: Base64`.

Consequence: the public TLS of Artemis now depends on frostlink. If the PushSecret of frostlink
stops working, or the cluster is rebuilt, Artemis serves a stale cert once the current one
expires. The fallback is to re-issue locally. Restore the `frostlink.dev` dns01 solver on
`letsencrypt-production` (apiTokenSecretRef `cloudflare-frostlink` in the cert-manager
namespace) plus a `Certificate`. Delete the importing ExternalSecret so the two do not
fight over the same secret name. Both are in git history.

Cert-manager no longer manages this secret, so the expiry
metrics of cert-manager do not cover it.

`dcunha-io-tls` is unaffected by any of this. It covers `dcunha.io` and `*.dcunha.io`, cert-manager
issues it here (Let's Encrypt DNS-01 through the Cloudflare API), and it does not depend
on the tunnel. towonel passes TLS through, so Envoy on Artemis presents this cert to every public
visitor.

## DNS — two ingress paths share the frostlink.dev zone

| Record                      | Cloud  | Path                    |
| --------------------------- | ------ | ----------------------- |
| `-> external.frostlink.dev` | ORANGE | cloudflared (frostlink) |
| `-> edge.frostlink.dev`     | GREY   | towonel (Artemis)       |

Anything served from Artemis MUST be grey. A proxied record hands the connection to
Cloudflare. Cloudflare terminates TLS and so cannot forward raw SNI, and it will not carry
arbitrary TCP at all on this plan.

The base record is a single grey `*.frostlink.dev` CNAME -> `edge.frostlink.dev`. Nobody
creates it by hand. It lives in `app/dnsendpoint.yaml` with the `cloudflare-proxied: "false"`
`providerSpecific` override, and `external-dns-frostlink` publishes it. Do not edit the record in the Cloudflare UI, because `policy: sync`
puts it back.

Specific records beat a wildcard, so the own orange entries of frostlink keep working untouched. The
corollary: a future frostlink app needs its own explicit record. Otherwise it falls through the wildcard
to Artemis.

### The collision guard

The external-dns of frostlink runs `policy: sync` with `txtOwnerId: frostlink` over the same
zone. `sync` deletes records that it believes it owns. A second controller on the same
zone must therefore differ in both of these values. Otherwise the two clusters delete each other in a loop:

```yaml
txtOwnerId: artemis # not frostlink
txtPrefix: k8s.artemis.%{record_type}- # not frostlink's prefix
```

The owner id decides what the controller deletes. The prefix decides whether the two
controllers can even see the ownership TXT records of each other. Matching prefixes with
different owner ids cause the loop, because the controllers overwrite the registry entries of each other. Also
omit `--cloudflare-proxied` on this instance so that records default to grey.

This is a real case here. The `external-dns-cloudflare` of frostlink runs
`--txt-owner-id=frostlink --txt-prefix=k8s.%{record_type}-`. That is the identical prefix that the own
`external-dns-cloudflare` of Artemis uses (owner `artemis-cluster`). If you copy the usual prefix of this repo onto
the frostlink instance, the two collide directly. The `external-dns-frostlink` of Artemis therefore runs
`--txt-owner-id=artemis --txt-prefix=k8s.artemis.%{record_type}-`, and omits `--cloudflare-proxied`.

The Cloudflare credential already exists as the `cloudflare-frostlink` item in the
`frostlink` vault. It is the full credential set of frostlink (tunnel id/secret, R2 keys,
account tag). Its `CF_TOKEN` is already scoped to the single `frostlink.dev` zone,
and `CF_ZONE_ID` is correct. No new item is needed. The ExternalSecret template maps only
`CF_TOKEN` and `CF_ZONE_ID` out of it, so nothing else reaches the cluster.

This lives in `kubernetes/apps/network/frostlink-dns/`. It is deliberately a _second_
external-dns, because the primary `cloudflare-dns` instance is pinned to the `dcunha.io`
zone by both `domainFilters` and `--zone-id-filter` and structurally cannot serve this.

### The dcunha.io zone — `edge-dns`, and the tunnel retirement

Public `*.dcunha.io` records for `edge-gateway` routes come from `external-dns-edge`
(`kubernetes/apps/network/edge-dns/`). It writes a grey CNAME per route →
`edge.frostlink.dev`. These settings keep it apart from `external-dns-cloudflare` on the same zone:

| Setting               | Value                                              |
| --------------------- | -------------------------------------------------- |
| `--annotation-prefix` | `edge-dns.kubernetes.io/`                          |
| `--gateway-name`      | `edge-gateway`                                     |
| target                | Gateway annotation `edge-dns.kubernetes.io/target` |
| `txtOwnerId`          | `artemis-edge`                                     |
| `txtPrefix`           | `k8s.edge.%{record_type}-`                         |

The prefixed annotation lets one Gateway carry two targets. `external-dns-unifi` reads the standard
`external-dns.kubernetes.io/target: edge.dcunha.io` and resolves it
to `10.10.99.90` on the LAN, while `edge-dns` reads only its own prefix. There is no `--cloudflare-proxied`,
so records are grey. This is the same rule as for frostlink.dev above.

This list shows what else is in the zone now that the tunnel is retired:

- Someone deleted the hand-made `*.dcunha.io` → tunnel wildcard and the public `external.dcunha.io` record.
  A name with no route of its own is now NXDOMAIN publicly.
- `edge.dcunha.io CNAME edge.frostlink.dev`, grey, from
  `kubernetes/apps/network/towonel-agent/app/dnsendpoint.yaml` (the `crd` source of `external-dns-cloudflare` reads it).
  It exists for IPv6 LAN clients. See `networking.md` § The LAN-side AAAA leak.
- The own Cloudflare tunnel of frostlink serves `status.dcunha.io`. That tunnel still exists (it
  also serves `hub.frostlink.dev`). The orange CNAME for it is a DNSEndpoint in
  `kubernetes/apps/network/cloudflare-dns/app/dnsendpoint.yaml`. `${FROSTLINK_TUNNEL_ID}` is
  substituted from ExternalSecret `cloudflare-dns-tunnel` (vault `frostlink`, item
  `cloudflare-frostlink`, field `CLOUDFLARE_TUNNEL_ID`). Bootstrap seeds the target secret
  `cloudflare-dns-tunnel-secret`.

### The frostlink instance runs `sources: [crd]` only — do not add `gateway-httproute`

Every Artemis Gateway carries an `external-dns.kubernetes.io/target` that points at a `dcunha.io`
LAN name (`edge-gateway`: `edge.dcunha.io`). In the `gateway-httproute` source, the target comes from the
Gateway annotation. A `target` annotation on the individual HTTPRoute does not
override it. It once published `echo.frostlink.dev CNAME external.dcunha.io`.

So the frostlink instance watches the CRD source only. The grey `*.frostlink.dev` wildcard CNAME
resolves every published hostname. That is the whole point of the
one-time wildcard design. Per-name records are redundant _and_ inherit the wrong target.
If a specific record is ever genuinely needed, add it to the DNSEndpoint.

To publish an app, add an HTTPRoute with a `frostlink.dev` hostname on
`edge-gateway`, and no DNS annotation at all. A public `dcunha.io` hostname is the same
HTTPRoute on the same gateway, and `edge-dns` writes its record. A route attached to
`external-gateway` never reaches the public.

### TCP routes by port, not hostname

A raw TCP service has no TLS, so it has no SNI, so the edge routes it by listen port. One
port serves one server. For several servers, use SRV records (`_minecraft._tcp.<name>` -> edge:port) so players
can type a bare hostname.

Scanners constantly probe a published TCP port on the VPS. The frostlink edge logs a steady trickle
of `Connection reset by peer (os error 104)` and `Connection timed out (os error 110)` from
unrelated internet addresses. That is background noise, not a fault.

On the CRD source, the source ignores a `cloudflare-proxied` annotation on the DNSEndpoint object.
It must be `providerSpecific` on the endpoint itself.

## Getting an invite token

The frostlink hub issues the token, scoped to the hostnames that the agent can claim. Run this from a
session with frostlink access:

```bash
kubectl --context=frostlink -n towonel exec ds/towonel -c main -- cat /data/operator.key > /tmp/opkey
curl -sS -X POST https://hub.frostlink.dev/v1/invites \
  -H "Authorization: Bearer $(cat /tmp/opkey)" -H 'content-type: application/json' \
  -d '{"name":"artemis","hostnames":["*.frostlink.dev","*.dcunha.io","dcunha.io"]}'
```

No TCP/UDP services are set today, so the invite carries no port grants. If you re-add one, the
invite also needs `"tcp_ports":[<port>]` / `"udp_ports":[<port>]`. The port grants are part of
the invite, not the agent config. If you add a TCP/UDP service to
`TOWONEL_AGENT_*_SERVICES` without a matching grant, the edge refuses to bind the
listener, with no error on the agent side.

The `token` (`tt_inv_2_…`) in the response is the only secret. It embeds the hub
identity, so the agent needs no hub URL. Revoke it with
`DELETE /v1/invites/{invite_id}`. The `towonel-ops` skill in the frostlink repo covers this.

The hostnames of the invite must match `TOWONEL_AGENT_SERVICES`. The `artemis` invite now lists
`*.frostlink.dev`, `*.dcunha.io` and `dcunha.io`. To add hostnames to an existing invite, use
the hub CLI inside the frostlink towonel pod, with the operator key at `/data/operator.key`:
`towonel invite add-hostnames --id <id> --hostnames <h>`. Matching is exact-string, so the
apex needed its own entry. `*.dcunha.io` does not cover `dcunha.io`.

The user must create the 1Password item. `op item create` from an agent session
returns `(101) You do not have permission`. The item lives in the `artemis`
vault. The store reads only the vaults that
`kubectl get clustersecretstore onepassword-connect -o jsonpath='{.spec.provider.onepassword.vaults}'` lists.

```bash
op item create --vault artemis --category "API Credential" --title towonel \
  "TOWONEL_INVITE_TOKEN[password]=<token>"
```

Then use the standard ExternalSecret pattern (`dataFrom.extract.key: towonel`). Declare it inline
under `externalSecrets.env` of the HelmRelease. Consume it as a `secretKeyRef` (Secret
`towonel-agent`) on the `TOWONEL_INVITE_TOKEN` env var.

The `frostlink.dev` Cloudflare token already exists as the `cloudflare-frostlink` item
in the `frostlink` vault (see § The collision guard). It serves `frostlink-dns`. It is zone-scoped to
`frostlink.dev` only. It is not a copy of the private key of frostlink. Cloudflare has no TXT-only grant, so the token
can edit any record in that zone. That is the accepted floor.

## Shape

`kubernetes/apps/network/towonel-agent/` holds `ks.yaml` plus `app/`, which holds
`ocirepository.yaml`, `helmrelease.yaml` (ExternalSecret inline under `externalSecrets:`) and
`dnsendpoint.yaml`. The second external-dns is a sibling app at
`kubernetes/apps/network/frostlink-dns/`. `towonel-agent/ks.yaml` has no `dependsOn` on it.

This app is app-template, so the hardening is written out explicitly and not
inherited from chart defaults. Take these values from bjw-s verbatim:
`automountServiceAccountToken: false`, `runAsNonRoot` with uid/gid/fsGroup 10001,
`seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`,
`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`. Health is `/healthz` on
port 9090 for all three probes, with a 60-failure startup budget (the agent can take
a while to establish the iroh connection) and `timeoutSeconds: 3` on liveness.
1 second is too tight and causes spurious restarts.

The agent is stateless. It has no PVC and no kopiur. All state is the invite token.

Memory is sized for bursts, not idle. The agent idles near 25-50Mi, but it buffers every stream
that it relays, and apoci federation opens one download per layer (2-3 per digest) when a peer pushes
an image. A ~10-layer image drove the agent past the old 128Mi limit. Each OOM restart dropped every
public connection on both domains for a few seconds, and the apoci of frostlink logged
`eager replication failed … EOF` for every in-flight blob. At 512Mi, a 19-blob, ~400MB parallel
pull through the tunnel ran clean (2026-10-27). If the agent OOMs again, raise the limit. Do not
throttle apoci, because its replication concurrency is not configurable.

Write the manifests comment-free. `yaml-conventions.md` forbids prose in
`kubernetes/`. The rationale lives here instead.

## PROXY protocol — the one that will bite you

Passthrough services prepend a HAProxy PROXY protocol v2 header by default
(`proxy_protocol` defaults to `v2` for `TOWONEL_AGENT_SERVICES`, and `none` for TCP
services). An Envoy listener that does not expect the header reads it as request bytes and
drops the connection. The symptoms point away from the real cause:

- The client sees `tlsv1 alert protocol version` (alert 70), which looks like a TLS version problem.
- The agent logs `edge->origin: Broken pipe (os error 32)` and
  `stream error: forwarding ended with a copy error`.
- Envoy tested directly (port-forward + `openssl s_client -servername`) works perfectly
  and serves the right cert by SNI.

Upstream documents this under "Passthrough behind Envoy / Envoy Gateway". There are two ways out:

| Option                         | Cost                                                   |
| ------------------------------ | ------------------------------------------------------ |
| `"proxy_protocol":"none"`      | origin sees the agent's pod IP, not the real client IP |
| Enable PROXY protocol on Envoy | needs a dedicated Gateway                              |

### The second option is the one in use — do not "fix" it back

The two halves are load-bearing together:

| Where                                   | Setting                                    |
| --------------------------------------- | ------------------------------------------ |
| `TOWONEL_AGENT_SERVICES`                | no `proxy_protocol` key → the `v2` default |
| `ClientTrafficPolicy/edge` in `network` | `proxyProtocol.optional: true`             |

`edge-gateway` exists precisely so that this can be turned on for towonel without touching the other
gateways. It could never be done on `external-gateway`, which served cloudflared and LAN traffic
and would have broken for both. The agent logs a real public client
address (`client: <client-ip>`, `hostname: jellyfin.frostlink.dev`), so real client IPs
are preserved end to end. Per-IP rate limiting and meaningful access logs are available on this
path.

`optional: true` is set because LAN clients connect to `10.10.99.90` directly with no header. It lets
Envoy accept both cases: header present (towonel) or absent
(LAN). One side effect: for server-speaks-first TCP on this gateway, Envoy waits for the first
bytes of the client to look for a header. SSH clients send first, so git over SSH works. Tools like
`ssh-keyscan` can hang.

There are two ways to break it:

- Remove `ClientTrafficPolicy/edge` while the agent still sends v2. Envoy then treats the header
  as the first bytes of the TLS ClientHello and resets every public connection. It looks like a
  TLS fault.
- Flip `optional: false`. Public traffic keeps working, but every LAN client is reset.

Adding `"proxy_protocol":"none"` to `TOWONEL_AGENT_SERVICES` no longer breaks anything visibly.
It silently drops the real client IP, and every public request appears to come from the agent pod.

## Beyond HTTPS — TCP and UDP are live

The upstream chart calls these `agent.tcpServices[]` / `agent.udpServices[]`. This app is
deployed as app-template, so they are the env vars `TOWONEL_AGENT_TCP_SERVICES` and
`TOWONEL_AGENT_UDP_SERVICES`. None are set. The `minecraft` (25565/tcp)
and `eco` (3000/udp) entries were removed along with `mc.frostlink.dev`, because both apps are
commented out of `arcade/kustomization.yaml` and the open ports only drew scanners. The entry shape,
for re-adding one, is
`{"name":"<name>","origin":"<service>.<namespace>.svc.cluster.local:<port>","listen_port":<port>}`
(UDP entries also take `idle_timeout_secs`).

If you re-add one, three things follow that are not obvious:

- These services bypass `edge-gateway` entirely. The agent dials the app Service directly. Nothing
  about `frostlink-dev-tls`, the PROXY protocol policy, or HTTPRoutes applies to them.
- The edge binds those host ports only while an agent session exists. It logs
  `edge tcp listener bound port=25565` on registration and `unbinding` on session loss. So a
  port-reachability test proves nothing while the agent is down.
- The invite must grant the ports (`tcp_ports` / `udp_ports`, § Getting an invite token). Otherwise
  the edge silently declines to bind them.

The UDP path has no other monitoring. Artemis probes its own HTTPS hostnames, so a
dead tunnel shows up there, but a re-added TCP/UDP service would go dark silently. The
`TowonelEdgeNoSessions` alert of frostlink covers that. See § Verify.

## Jellyfin — the video path

The Jellyfin-compatible port of silo has served `jellyfin.dcunha.io` since 2026-10-27
(`media-stack.md` § Silo). `jellyfin.frostlink.dev` was retired at that cutover, because only the
Gatus probe still used it. When an app does need both domains, app-template supports multiple
named routes, so it is two route entries against one Service:

```yaml
route:
    app:
        hostnames: ["{{ .Release.Name }}.dcunha.io"]
        parentRefs: [{ name: edge-gateway, namespace: network }]
    frostlink:
        hostnames: ["{{ .Release.Name }}.frostlink.dev"]
        parentRefs: [{ name: edge-gateway, namespace: network }]
```

The terms of Cloudflare forbid serving video over the CDN, so towonel is the compliant
path for this, not a downgrade. No Jellyfin traffic touches Cloudflare.

Known and deliberately accepted: `jellyfin_compat.public_url` of silo (`JELLYFIN_PublishedServerUrl` of Jellyfin
before it) is pinned to the `dcunha.io` hostname. The
unauthenticated `/System/Info/Public` endpoint therefore returns `LocalAddress: https://jellyfin.dcunha.io`
to public clients. The home IP is not exposed (the
name resolves to the frostlink VPS) and it was already a public hostname, so the only leak is the
correlation between the two names.
The alternative is to point the published URL at `frostlink.dev`. That would make LAN
clients hairpin out to the VPS and back, and it would cap local playback at residential upload.
The clean fix, if the correlation ever matters, is to unset it entirely (the server then derives it per request).

### Bandwidth

OCI Always Free gives 10 TB/month egress. Artemis→frostlink is VPS _ingress_ and
uncounted, so each delivered byte counts once. The real ceiling is the residential
upload of Artemis (~20–50 Mbps), not the VPS. Expect seeking to feel worse than direct play.
An egress alert around 7 TB is still worth adding on the frostlink side.

## Gotchas

- Do not trust bare `dig` on the dev machine for `dcunha.io`. Split-horizon DNS
  returns the internal answer. Query `@1.1.1.1` / `@8.8.8.8` explicitly. This cost real
  time: a correct record looked broken.
- The pre-commit hook rewrites `$schema` in `kustomization.yaml` to
  `k8s-schemas.home-operations.com` (frostlink uses `json.schemastore.org`) and stages the
  rewrite. Never use `--no-verify` to get around it.
- Missing UDP fails silently. frostlink must have UDP 51820 open. If agents reach
  the hub via relay but never go direct, suspect the UDP rule.
- The default relay is whatever the hub advertises (the public relays of n0). Set
  `relayUrl` only to override it. `directConnect` is for NodePort-based relay-less
  connectivity and is not needed to start.
- A public request that gets `403` or a challenge page from a site that works on the LAN is usually
  CrowdSec on frostlink: a ban on the client IP, or a missing bot-challenge exemption. Fix it in the
  frostlink repo, not here.

## Verify

1. Run `curl https://<name>.frostlink.dev`. It answers with the `frostlink-dev-tls` cert. frostlink
   issues that cert and Artemis imports it (§ The certificate), so the cert alone cannot tell
   passthrough from terminate mode any more. Make sure of the mode from the startup log of the agent
   instead: `published TLS policy to hub` with `"hostname":"*.frostlink.dev","mode":"passthrough"`
   (`kubectl -n network logs deploy/towonel-agent | grep 'TLS policy'`).
2. Make sure that `towonel_edge_active_sessions` on the frostlink hub is at least 1 while the agent runs.
3. Make sure that `TowonelEdgeNoSessions` in `app/prometheusrule-edge.yaml` of frostlink is enabled. It is the only
   alert that catches a dead tunnel for TCP/UDP services. Leave it on.
