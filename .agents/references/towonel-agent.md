# towonel Agent — Artemis-Cluster

How Artemis services are published through the **towonel** tunnel running on frostlink.

**Deployed and operational.** `kubernetes/apps/network/towonel-agent/` holds a `HelmRelease` (its
ExternalSecret inline under `externalSecrets:`), `DNSEndpoint` and `OCIRepository`. `edge-gateway`
carries **every** public route on Artemis, `*.frostlink.dev` and `*.dcunha.io` alike; the Artemis
Cloudflare tunnel is retired (§ The dcunha.io zone).

Upstream: <https://codeberg.org/towonel/towonel>. Deployed here as **app-template**
(`oci://ghcr.io/bjw-s-labs/helm/app-template`) running the
`codeberg.org/towonel/towonel-agent` **image** — not the upstream `towonel-agent` chart. Both
versions: `grep -h 'tag:' kubernetes/apps/network/towonel-agent/app/*.yaml`. This follows
bjw-s-labs/home-ops and keeps the app on this repo's one-OCIRepository-per-app convention. Config is therefore **environment
variables** (`TOWONEL_AGENT_*`), not chart values.

## What it is, and why Artemis wants it

frostlink (the public Oracle Cloud VPS, separate repo) runs the towonel **hub** and
**edge**. An agent here dials **out** over iroh QUIC and holds the connection open,
so Artemis publishes public hostnames without opening a single inbound port.

The edge peeks at SNI and forwards the **raw TLS stream** to the agent, which hands
it to a local origin. Nothing in the middle terminates TLS.

> **Repo boundary.** frostlink and Artemis stay separate repos. The entire interface
> is **one invite token and a hostname**. Do not share manifests, components, or
> propose a monorepo.

## The design that worked

Point the agent at **this cluster's own gateway**, with one wildcard entry per domain:

```yaml
TOWONEL_AGENT_SERVICES: |
    [{"hostname":"*.frostlink.dev","origin":"edge-gateway.network.svc.cluster.local:443"},
     {"hostname":"*.dcunha.io","origin":"edge-gateway.network.svc.cluster.local:443"},
     {"hostname":"dcunha.io","origin":"edge-gateway.network.svc.cluster.local:443"}]
```

Two things follow, and both matter:

1. **Publishing more hostnames under either domain is just a normal HTTPRoute** on
   `edge-gateway`. Only a new _domain_ touches towonel: it needs an entry here **and** on the
   hub invite (§ Getting an invite token).
2. **The `frostlink.dev` certificate is frostlink's, imported through 1Password** — Artemis no
   longer issues its own. See § The certificate, and the key note below for why a second
   key buys no protection. `dcunha.io` uses Artemis's own `dcunha-io-tls`.

Service names here are literally the Gateway names (`edge-gateway`, `external-gateway`)
— envoy-gateway does not apply its `envoy-<ns>-<gw>-<hash>` naming in this cluster.

### Which gateway to attach a route to

This is the whole ergonomic point of the split, and it is the only rule you need:

| Hostname                | `parentRefs`       | `sectionName`           | Path                      |
| ----------------------- | ------------------ | ----------------------- | ------------------------- |
| `*.frostlink.dev`       | `edge-gateway`     | `https`, or none        | towonel (public, via VPS) |
| `*.dcunha.io`, public   | `edge-gateway`     | `https-dcunha`, or none | towonel (public, via VPS) |
| `dcunha.io` apex        | `edge-gateway`     | `https-dcunha-apex`     | towonel (public, via VPS) |
| `*.dcunha.io`, LAN only | `internal-gateway` | `https`, or none        | LAN only                  |

`external-gateway` takes **no new routes**. It still exists (`10.10.99.97`) but carries nothing
except the shared `https-redirect`; its only upstream, the Cloudflare tunnel, is gone.

`edge-gateway` is a **LoadBalancer on `10.10.99.90`** (LAN name `edge.dcunha.io`). It has three `:443` listeners:
`https` (no hostname, `frostlink-dev-tls`), `https-dcunha` (`*.dcunha.io`, `dcunha-io-tls`) and
`https-dcunha-apex` (`dcunha.io`, same cert — the wildcard listener does not match the apex).
Public traffic reaches it through towonel; LAN clients hit `10.10.99.90` directly.

**The `sectionName: https` trap.** On `internal-gateway`/`external-gateway`, `https` is the
`dcunha.io` listener. On `edge-gateway` it is the `frostlink.dev` one, so a `*.dcunha.io` route
that pins `sectionName: https` never attaches. Moving a route from `external-gateway` means
changing the parentRef **and** any `sectionName: https` to `https-dcunha`. Auth SecurityPolicies
(tinyauth, envoy-oidc) target the HTTPRoute, not the gateway, so they follow the route unchanged.

**Withholding frostlink's key from Artemis protects nothing.** frostlink **already holds a
publicly-trusted `*.frostlink.dev` private key** on its own cluster (it exports it to 1Password).
If frostlink's VPS is compromised, the attacker controls the edge _and_ already has a valid
wildcard key for those names, so they can terminate TLS themselves and MITM Artemis-bound traffic.
Withholding a second key does not prevent that; separation would buy only independent rotation
and fewer copies of a key in flight.

## The certificate

`frostlink-dev-tls` in `network` is **imported from 1Password**, not issued here. frostlink
issues it and pushes it; Artemis pulls it. It covers `frostlink.dev` **and**
`*.frostlink.dev`, so it is strictly better than the wildcard-only cert Artemis used to
issue for itself.

**The import must refresh.** Copy the shape from
`certificates/import/frostlink-externalsecret.yaml`, _not_ from the neighbouring
`externalsecret.yaml`. The frostlink import sets no `refreshPolicy`, so it keeps the ExternalSecret
defaults: `refreshInterval` 1h and `creationPolicy: Owner`. The dcunha import is deliberately
**bootstrap-only** (`refreshPolicy: CreatedOnce`, `creationPolicy: Orphan`): it seeds the secret
once and then cert-manager owns renewal. Copying that pattern here would pull the cert once and
never pick up a renewal, so Artemis would silently serve an **expired** certificate at
frostlink's next rollover.

Both values are base64-encoded in the 1Password item, hence `decodingStrategy: Base64`.

**Consequence: Artemis's public TLS now depends on frostlink.** If frostlink's PushSecret
stops working, or the cluster is rebuilt, Artemis serves a stale cert once the current one
expires. The fallback is to re-issue locally — restore the `frostlink.dev` dns01 solver on
`letsencrypt-production` (apiTokenSecretRef `cloudflare-frostlink` in the cert-manager
namespace) plus a `Certificate`, and delete the importing ExternalSecret so the two do not
fight over the same secret name. Both are in git history.

Note this secret is **not** cert-manager-managed any more, so cert-manager's expiry
metrics do not cover it.

**`dcunha-io-tls` is unaffected by any of this.** It covers `dcunha.io` and `*.dcunha.io`, is
issued here by cert-manager (Let's Encrypt DNS-01 through the Cloudflare API), and does not depend
on the tunnel. towonel passes TLS through, so Envoy on Artemis presents it to every public
visitor.

## DNS — two ingress paths share the frostlink.dev zone

| Record                      | Cloud  | Path                    |
| --------------------------- | ------ | ----------------------- |
| `-> external.frostlink.dev` | ORANGE | cloudflared (frostlink) |
| `-> edge.frostlink.dev`     | GREY   | towonel (Artemis)       |

**Anything served from Artemis MUST be grey.** A proxied record hands the connection to
Cloudflare, which terminates TLS and so cannot forward raw SNI, and will not carry
arbitrary TCP at all on this plan.

The base record is a single **grey `*.frostlink.dev` CNAME -> `edge.frostlink.dev`**. It is
**not** hand-created — it lives in `app/dnsendpoint.yaml` with the `cloudflare-proxied: "false"`
`providerSpecific` override, and `external-dns-frostlink` publishes it. Editing the record in the Cloudflare UI is therefore pointless: `policy: sync`
puts it back.

Specific records beat a wildcard, so frostlink's own orange entries keep working untouched. The
corollary: a future frostlink app needs its own explicit record, or it falls through the wildcard
to Artemis.

### The collision guard

frostlink's external-dns runs `policy: sync` with `txtOwnerId: frostlink` over the same
zone. `sync` deletes records it believes it owns, so a second controller on the same
zone must differ in **both** of these or the two clusters delete each other in a loop:

```yaml
txtOwnerId: artemis # not frostlink
txtPrefix: k8s.artemis.%{record_type}- # not frostlink's prefix
```

The owner id decides what it will delete; the **prefix decides whether the two
controllers can even see each other's ownership TXT records**. Matching prefixes with
different owner ids is the loop — they overwrite each other's registry entries. Also
omit `--cloudflare-proxied` on this instance so records default to grey.

This is not hypothetical here: frostlink's `external-dns-cloudflare` runs
`--txt-owner-id=frostlink --txt-prefix=k8s.%{record_type}-` — **the identical prefix Artemis's own
`external-dns-cloudflare` uses** (owner `artemis-cluster`). Copying this repo's usual prefix onto
the frostlink instance would collide directly. Artemis's `external-dns-frostlink` therefore runs
`--txt-owner-id=artemis --txt-prefix=k8s.artemis.%{record_type}-`, and omits `--cloudflare-proxied`.

The Cloudflare credential already exists as the `cloudflare-frostlink` item in the
`frostlink` vault — it is frostlink's full credential set (tunnel id/secret, R2 keys,
account tag) and its `CF_TOKEN` is already scoped to the single `frostlink.dev` zone,
with `CF_ZONE_ID` correct. No new item is needed; the ExternalSecret template maps only
`CF_TOKEN` and `CF_ZONE_ID` out of it, so nothing else reaches the cluster.

This lives in `kubernetes/apps/network/frostlink-dns/` — deliberately a _second_
external-dns, because the primary `cloudflare-dns` instance is pinned to the `dcunha.io`
zone by both `domainFilters` and `--zone-id-filter` and structurally cannot serve this.

### The dcunha.io zone — `edge-dns`, and the tunnel retirement

Public `*.dcunha.io` records for `edge-gateway` routes come from `external-dns-edge`
(`kubernetes/apps/network/edge-dns/`). It writes a **grey** CNAME per route →
`edge.frostlink.dev`. It is kept apart from `external-dns-cloudflare` on the same zone by:

| Setting               | Value                                              |
| --------------------- | -------------------------------------------------- |
| `--annotation-prefix` | `edge-dns.kubernetes.io/`                          |
| `--gateway-name`      | `edge-gateway`                                     |
| target                | Gateway annotation `edge-dns.kubernetes.io/target` |
| `txtOwnerId`          | `artemis-edge`                                     |
| `txtPrefix`           | `k8s.edge.%{record_type}-`                         |

The prefixed annotation is what lets one Gateway carry two targets: the standard
`external-dns.kubernetes.io/target: edge.dcunha.io` is read by `external-dns-unifi` and resolves
to `10.10.99.90` on the LAN, while `edge-dns` reads only its own prefix. No `--cloudflare-proxied`,
so records are grey — the same rule as frostlink.dev above.

What else is in the zone now that the tunnel is retired:

- The hand-made `*.dcunha.io` → tunnel wildcard and the public `external.dcunha.io` record were
  **deleted**. A name with no route of its own is now NXDOMAIN publicly.
- `edge.dcunha.io CNAME edge.frostlink.dev`, grey, from
  `kubernetes/apps/network/towonel-agent/app/dnsendpoint.yaml` (read by `external-dns-cloudflare`'s
  `crd` source). It exists for IPv6 LAN clients — `networking.md` § The LAN-side AAAA leak.
- `status.dcunha.io` is served by **frostlink's own** Cloudflare tunnel, which still exists (it
  also serves `hub.frostlink.dev`). Its orange CNAME is a DNSEndpoint in
  `kubernetes/apps/network/cloudflare-dns/app/dnsendpoint.yaml`, with `${FROSTLINK_TUNNEL_ID}`
  substituted from ExternalSecret `cloudflare-dns-tunnel` (vault `frostlink`, item
  `cloudflare-frostlink`, field `CLOUDFLARE_TUNNEL_ID`). Bootstrap seeds the target secret
  `cloudflare-dns-tunnel-secret`.

### The frostlink instance runs `sources: [crd]` only — do not add `gateway-httproute`

Every Artemis Gateway carries an `external-dns.kubernetes.io/target` pointing at a `dcunha.io`
LAN name (`edge-gateway`: `edge.dcunha.io`). In the `gateway-httproute` source the **target comes from the
Gateway annotation**, and putting a `target` annotation on the individual HTTPRoute does **not**
override it — it once published `echo.frostlink.dev CNAME external.dcunha.io`.

So the frostlink instance watches the CRD source only. Every published hostname is
resolved by the grey `*.frostlink.dev` wildcard CNAME, which is the whole point of the
one-time wildcard design — per-name records are redundant _and_ inherit the wrong target.
If a specific record is ever genuinely needed, add it to the DNSEndpoint.

Publishing an app is therefore just an HTTPRoute with a `frostlink.dev` hostname on
**`edge-gateway`**, and no DNS annotation at all. A public `dcunha.io` hostname is the same
HTTPRoute on the same gateway; `edge-dns` writes its record. A route attached to
`external-gateway` never reaches the public.

### TCP routes by port, not hostname

There is no TLS on a raw TCP service, so no SNI, so the edge routes it **by listen port**. One
port = one server. For several, use SRV records (`_minecraft._tcp.<name>` -> edge:port) so players
can type a bare hostname.

**A published TCP port on the VPS is scanned constantly.** The frostlink edge logs a steady trickle
of `Connection reset by peer (os error 104)` and `Connection timed out (os error 110)` from
unrelated internet addresses. That is background noise, not a fault.

On the **CRD source a `cloudflare-proxied` annotation on the DNSEndpoint object is
ignored** — it must be `providerSpecific` on the endpoint itself.

## Getting an invite token

Issued by the frostlink hub, scoped to the hostnames the agent may claim. From a
session with frostlink access:

```bash
kubectl --context=frostlink -n towonel exec ds/towonel -c main -- cat /data/operator.key > /tmp/opkey
curl -sS -X POST https://hub.frostlink.dev/v1/invites \
  -H "Authorization: Bearer $(cat /tmp/opkey)" -H 'content-type: application/json' \
  -d '{"name":"artemis","hostnames":["*.frostlink.dev","*.dcunha.io","dcunha.io"]}'
```

No TCP/UDP services are set today, so the invite carries no port grants. If one is re-added, the
invite also needs `"tcp_ports":[<port>]` / `"udp_ports":[<port>]`: the port grants are part of
the invite, not the agent config. Adding a TCP/UDP service to
`TOWONEL_AGENT_*_SERVICES` without a matching grant leaves the edge refusing to bind the
listener, with no error on the agent side.

The response's `token` (`tt_inv_2_…`) is the only secret. It **embeds the hub
identity**, so the agent needs no hub URL. Revoke with
`DELETE /v1/invites/{invite_id}`. The frostlink repo's `towonel-ops` skill covers this.

**The invite's hostnames must match `TOWONEL_AGENT_SERVICES`.** The `artemis` invite now lists
`*.frostlink.dev`, `*.dcunha.io` and `dcunha.io`. Hostnames are added to an existing invite with
the hub CLI inside the frostlink towonel pod, using the operator key at `/data/operator.key`:
`towonel invite add-hostnames --id <id> --hostnames <h>`. Matching is **exact-string**, so the
apex needed its own entry — `*.dcunha.io` does not cover `dcunha.io`.

**The 1Password item must be created by the user** — `op item create` from an agent session
returns `(101) You do not have permission`. It lives in the `artemis`
vault; the store reads only the vaults listed by
`kubectl get clustersecretstore onepassword-connect -o jsonpath='{.spec.provider.onepassword.vaults}'`.

```bash
op item create --vault artemis --category "API Credential" --title towonel \
  "TOWONEL_INVITE_TOKEN[password]=<token>"
```

Then the standard ExternalSecret pattern (`dataFrom.extract.key: towonel`), declared inline
under the HelmRelease's `externalSecrets.env` and consumed as a `secretKeyRef` (Secret
`towonel-agent`) on the `TOWONEL_INVITE_TOKEN` env var.

The `frostlink.dev` Cloudflare token already exists as the `cloudflare-frostlink` item
in the `frostlink` vault (see § The collision guard). It serves `frostlink-dns`. It is zone-scoped to
`frostlink.dev` only — not a copy of frostlink's private key. Cloudflare has no TXT-only grant, so it
can edit any record in that zone; that is the accepted floor.

## Shape

`kubernetes/apps/network/towonel-agent/` — `ks.yaml` plus `app/` holding
`ocirepository.yaml`, `helmrelease.yaml` (ExternalSecret inline under `externalSecrets:`),
`dnsendpoint.yaml`. The second external-dns is a sibling app at
`kubernetes/apps/network/frostlink-dns/`; `towonel-agent/ks.yaml` has no `dependsOn` on it.

Because this is app-template, the hardening is written out explicitly rather than
inherited from chart defaults — take these from bjw-s verbatim:
`automountServiceAccountToken: false`, `runAsNonRoot` with uid/gid/fsGroup 10001,
`seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`,
`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`. Health is `/healthz` on
port 9090 for all three probes, with a **60-failure startup budget** (the agent can take
a while to establish the iroh connection) and **`timeoutSeconds: 3` on liveness** —
1 second is too tight and causes spurious restarts.

The agent is stateless — no PVC, no kopiur. All state is the invite token.

**Memory is sized for bursts, not idle.** The agent idles near 25-50Mi but buffers every stream
it relays, and apoci federation opens one download per layer (2-3 per digest) when a peer pushes
an image. A ~10-layer image drove it past the old 128Mi limit; each OOM restart dropped every
public connection on both domains for a few seconds, and frostlink's apoci logged
`eager replication failed … EOF` for every in-flight blob. At 512Mi a 19-blob, ~400MB parallel
pull through the tunnel ran clean (2026-10-27). If it OOMs again, raise the limit; do not
throttle apoci — its replication concurrency is not configurable.

**Write the manifests comment-free** — `yaml-conventions.md` forbids prose in
`kubernetes/`. The rationale lives here instead.

## PROXY protocol — the one that will bite you

Passthrough services prepend a **HAProxy PROXY protocol v2 header** by default
(`proxy_protocol` defaults to `v2` for `TOWONEL_AGENT_SERVICES`, and `none` for TCP
services). An Envoy listener that is not expecting it reads that header as request bytes and
drops the connection. Symptoms, which point away from the real cause:

- client sees `tlsv1 alert protocol version` (alert 70) — looks like a TLS version problem
- agent logs `edge->origin: Broken pipe (os error 32)` and
  `stream error: forwarding ended with a copy error`
- Envoy tested directly (port-forward + `openssl s_client -servername`) works perfectly,
  serving the right cert by SNI

Upstream documents it under "Passthrough behind Envoy / Envoy Gateway". Two ways out:

| Option                         | Cost                                                       |
| ------------------------------ | ---------------------------------------------------------- |
| `"proxy_protocol":"none"`      | origin sees the **agent's pod IP**, not the real client IP |
| Enable PROXY protocol on Envoy | needs a **dedicated** Gateway                              |

### The second option is the one in use — do not "fix" it back

The two halves are load-bearing together:

| Where                                   | Setting                                        |
| --------------------------------------- | ---------------------------------------------- |
| `TOWONEL_AGENT_SERVICES`                | **no `proxy_protocol` key** → the `v2` default |
| `ClientTrafficPolicy/edge` in `network` | `proxyProtocol.optional: true`                 |

`edge-gateway` exists precisely so this can be turned on for towonel without touching the other
gateways. It could never be done on `external-gateway`, which served cloudflared and LAN traffic
and would have broken for both. The agent logs a real public client
address (`client: <client-ip>`, `hostname: jellyfin.frostlink.dev`), so **real client IPs
are preserved end to end** — per-IP rate limiting and meaningful access logs are available on this
path.

**`optional: true`** because LAN clients hit `10.10.99.90` directly with no header, and it lets
Envoy accept both: header present (towonel) or absent
(LAN). One side effect: for server-speaks-first TCP on this gateway, Envoy waits for the client's
first bytes to look for a header. SSH clients send first, so git over SSH works; tools like
`ssh-keyscan` may hang.

Two ways to break it:

- Removing `ClientTrafficPolicy/edge` while the agent still sends v2. Envoy then treats the header
  as the first bytes of the TLS ClientHello and resets every public connection — it looks like a
  TLS fault.
- Flipping `optional: false`. Public traffic keeps working; every LAN client is reset.

Adding `"proxy_protocol":"none"` to `TOWONEL_AGENT_SERVICES` no longer breaks anything visibly —
it silently drops the real client IP, and every public request appears to come from the agent pod.

## Beyond HTTPS — TCP and UDP are live

The upstream chart calls these `agent.tcpServices[]` / `agent.udpServices[]`; because this app is
deployed as app-template, they are the env vars **`TOWONEL_AGENT_TCP_SERVICES`** and
**`TOWONEL_AGENT_UDP_SERVICES`**. **None are set**: the `minecraft` (25565/tcp)
and `eco` (3000/udp) entries were removed along with `mc.frostlink.dev` because both apps are
commented out of `arcade/kustomization.yaml` and the open ports only drew scanners. Entry shape,
for re-adding one:
`{"name":"<name>","origin":"<service>.<namespace>.svc.cluster.local:<port>","listen_port":<port>}`
(UDP entries also take `idle_timeout_secs`).

If one is re-added, three things follow that are not obvious:

- **These bypass `edge-gateway` entirely.** The agent dials the app Service directly. Nothing
  about `frostlink-dev-tls`, the PROXY protocol policy, or HTTPRoutes applies to them.
- **The edge binds those host ports only while an agent session exists** — it logs
  `edge tcp listener bound port=25565` on registration and `unbinding` on session loss. So a
  port-reachability test proves nothing while the agent is down.
- **The invite must grant the ports** (`tcp_ports` / `udp_ports`, § Getting an invite token), or
  the edge silently declines to bind them.

The UDP path is the one with no other monitoring: Artemis probes its own HTTPS hostnames, so a
dead tunnel shows up there, but a re-added TCP/UDP service would go dark silently. frostlink's
`TowonelEdgeNoSessions` alert is what covers that — see § Verify.

## Jellyfin — the video path

`jellyfin.dcunha.io` is served by silo's Jellyfin-compatible port since 2026-10-27
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

Cloudflare's terms forbid serving video over the CDN, so towonel is the **compliant**
path for this, not a downgrade — no Jellyfin traffic touches Cloudflare.

**Known and deliberately accepted:** silo's `jellyfin_compat.public_url` (Jellyfin's
`JELLYFIN_PublishedServerUrl` before it) is pinned to the `dcunha.io` hostname, so the
unauthenticated `/System/Info/Public` endpoint returns `LocalAddress: https://jellyfin.dcunha.io`
to public clients. The home IP is not exposed (the
name resolves to the frostlink VPS) and it was already a public hostname, so the only leak is the
correlation between the two names.
The alternative — pointing the published URL at `frostlink.dev` — would make **LAN**
clients hairpin out to the VPS and back, capping local playback at residential upload.
Unsetting it entirely (letting the server derive it per request) is the clean fix if the
correlation ever matters.

### Bandwidth

OCI Always Free gives 10 TB/month egress, and Artemis→frostlink is VPS _ingress_ and
uncounted, so each delivered byte counts once. The real ceiling is Artemis's residential
**upload** (~20–50 Mbps), not the VPS. Expect seeking to feel worse than direct play.
An egress alert around 7 TB is still worth adding on the frostlink side.

## Gotchas

- **Do not trust bare `dig` on the dev machine for `dcunha.io`** — split-horizon DNS
  returns the internal answer. Query `@1.1.1.1` / `@8.8.8.8` explicitly. This cost real
  time: a correct record looked broken.
- **The pre-commit hook rewrites `$schema` in `kustomization.yaml`** to
  `k8s-schemas.home-operations.com` (frostlink uses `json.schemastore.org`) and stages the
  rewrite. Never `--no-verify` around it.
- **Missing UDP fails silently.** frostlink must have UDP 51820 open. If agents reach
  the hub via relay but never go direct, suspect the UDP rule.
- Default relay is whatever the hub advertises (n0's public relays). Set
  `relayUrl` only to override. `directConnect` is for NodePort-based relay-less
  connectivity and is not needed to start.
- **A public request that gets `403` from a site that works on the LAN** is usually a CrowdSec
  ban on the client IP. LAN traffic is exempt, so it never shows there: `crowdsec.md`.

## Verify

1. `curl https://<name>.frostlink.dev` answers with the `frostlink-dev-tls` cert — frostlink
   issues it and Artemis imports it (§ The certificate), so the cert alone **cannot** tell
   passthrough from terminate mode any more. Confirm the mode from the agent's startup log
   instead: `published TLS policy to hub` with `"hostname":"*.frostlink.dev","mode":"passthrough"`
   (`kubectl -n network logs deploy/towonel-agent | grep 'TLS policy'`).
2. `towonel_edge_active_sessions` on the frostlink hub is at least 1 while the agent runs.
3. `TowonelEdgeNoSessions` in frostlink's `app/prometheusrule-edge.yaml` is enabled. It is the only
   alert that catches a dead tunnel for TCP/UDP services. Leave it on.
