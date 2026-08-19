# towonel Agent — Handoff

Plan for publishing Artemis services through the **towonel** tunnel running on
frostlink. Written 2026-08-18. **Not deployed yet** — a working version was built
and verified up to the secret step on 2026-08-18, then reverted to keep that day
scoped to frostlink. Everything below is what that attempt established, so this is
a plan with the unknowns already burned out of it.

Upstream: <https://codeberg.org/towonel/towonel>. Deployed here as **app-template**
(`oci://ghcr.io/bjw-s-labs/helm/app-template` 5.1.0) running the
`codeberg.org/towonel/towonel-agent` **image** at 1.5.3 — not the upstream
`towonel-agent` chart. This follows bjw-s-labs/home-ops and keeps the app on this
repo's one-OCIRepository-per-app convention. Config is therefore **environment
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

Point the agent at **this cluster's own gateway**, with a single wildcard entry:

```yaml
TOWONEL_AGENT_SERVICES: |
    [{"hostname":"*.frostlink.dev","origin":"edge-gateway.network.svc.cluster.local:443"}]
```

Two things follow, and both matter:

1. **Publishing more hostnames later is just a normal HTTPRoute** on `external-gateway`.
   The towonel config is a one-time change; towonel is never touched again.
2. **No private key crosses the repo boundary.** Artemis issues its _own_
   `*.frostlink.dev` certificate from a Cloudflare token scoped to the `frostlink.dev`
   zone. Two independently issued certs, one key each, neither cluster able to
   impersonate the other.

Service names here are literally the Gateway names (`edge-gateway`, `external-gateway`)
— envoy-gateway does not apply its `envoy-<ns>-<gw>-<hash>` naming in this cluster.
Verified live 2026-08-19.

### Which gateway to attach a route to

This is the whole ergonomic point of the split, and it is the only rule you need:

| Hostname          | `parentRefs`       | Path                      |
| ----------------- | ------------------ | ------------------------- |
| `*.dcunha.io`     | `external-gateway` | Cloudflare tunnel         |
| `*.frostlink.dev` | `edge-gateway`     | towonel (public, via VPS) |

`edge-gateway` is **ClusterIP, not LoadBalancer** — nothing but the towonel agent should
reach it, so it deliberately has no LAN address. It holds only `frostlink-dev-tls`;
`external-gateway` holds only `dcunha-io-tls`. Neither carries a cert for a domain it
does not serve.

> **Superseded 2026-08-19.** An earlier revision recommended publishing
> `<name>.dcunha.io` through the tunnel, to avoid copying frostlink's wildcard key onto
> Artemis. The requirement is that the public **only ever** sees `*.frostlink.dev`, so
> that is wrong on its face — do not publish a `dcunha.io` hostname through towonel.
>
> The key-copying concern was also overstated, and it is worth being precise about why.
> frostlink **already holds a publicly-trusted `*.frostlink.dev` private key** on its own
> cluster (it exports it to 1Password). So in the threat model that matters — frostlink's
> VPS is compromised — the attacker controls the edge _and_ already has a valid wildcard
> key for those names. They can stop passing through, terminate TLS themselves, and MITM
> Artemis-bound traffic with a certificate clients accept. Withholding a second key does
> not prevent that. Separation would buy independent rotation and fewer copies of a key
> in flight; it does **not** buy immunity from impersonation.

## The certificate

`frostlink-dev-tls` in `network` is **imported from 1Password**, not issued here. frostlink
issues it and pushes it; Artemis pulls it. It covers `frostlink.dev` **and**
`*.frostlink.dev`, so it is strictly better than the wildcard-only cert Artemis used to
issue for itself.

**The import must refresh.** Copy the shape from
`certificates/import/frostlink-externalsecret.yaml`, _not_ from the neighbouring
`externalsecret.yaml`:

| Field             | frostlink import | dcunha bootstrap import |
| ----------------- | ---------------- | ----------------------- |
| `refreshInterval` | `1h`             | —                       |
| `refreshPolicy`   | —                | `CreatedOnce`           |
| `creationPolicy`  | `Owner`          | `Orphan`                |

The dcunha import is deliberately **bootstrap-only**: it seeds the secret once and then
cert-manager owns renewal. Copying that pattern here would pull the cert once and never
pick up a renewal, so Artemis would silently begin serving an **expired** certificate at
frostlink's next rollover. That is the failure mode to avoid.

Both values are base64-encoded in the 1Password item, hence `decodingStrategy: Base64`.

**Consequence: Artemis's public TLS now depends on frostlink.** If frostlink's PushSecret
stops working, or the cluster is rebuilt, Artemis serves a stale cert once the current one
expires. The fallback is to re-issue locally — restore the `frostlink.dev` dns01 solver on
`letsencrypt-production` (apiTokenSecretRef `cloudflare-frostlink` in the cert-manager
namespace) plus a `Certificate`, and delete the importing ExternalSecret so the two do not
fight over the same secret name. Both are in git history as of 2026-08-19.

Note this secret is **not** cert-manager-managed any more, so cert-manager's expiry
metrics do not cover it.

## DNS — two ingress paths share the frostlink.dev zone

| Record                      | Cloud  | Path                    |
| --------------------------- | ------ | ----------------------- |
| `-> external.frostlink.dev` | ORANGE | cloudflared (frostlink) |
| `-> edge.frostlink.dev`     | GREY   | towonel (Artemis)       |

**Anything served from Artemis MUST be grey.** A proxied record hands the connection to
Cloudflare, which terminates TLS and so cannot forward raw SNI, and will not carry
arbitrary TCP at all on this plan.

The base record is a single **grey `*.frostlink.dev` CNAME -> `edge.frostlink.dev`**,
created by hand. Specific records beat a wildcard, so frostlink's own orange entries
keep working untouched. The corollary: a future frostlink app needs its own explicit
record, or it falls through the wildcard to Artemis.

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

This is not hypothetical here. Verified 2026-08-19 against the live zone: frostlink runs
`txtPrefix: k8s.%{record_type}-` (records like `k8s.cname-hub.frostlink.dev` carrying
`external-dns/owner=frostlink`) — **the identical prefix Artemis's primary
`cloudflare-dns` instance uses**. Copying this repo's usual prefix onto the frostlink
instance would have collided directly.

The Cloudflare credential already exists as the `cloudflare-frostlink` item in the
`kubernetes` vault — it is frostlink's full credential set (tunnel id/secret, R2 keys,
account tag) and its `CF_TOKEN` is already scoped to the single `frostlink.dev` zone,
with `CF_ZONE_ID` correct. No new item is needed; the ExternalSecret template maps only
`CF_TOKEN` and `CF_ZONE_ID` out of it, so nothing else reaches the cluster.

This lives in `kubernetes/apps/network/frostlink-dns/` — deliberately a _second_
external-dns, because the primary `cloudflare-dns` instance is pinned to the `dcunha.io`
zone by both `domainFilters` and `--zone-id-filter` and structurally cannot serve this.

### The frostlink instance runs `sources: [crd]` only — do not add `gateway-httproute`

`external-gateway` carries `external-dns.alpha.kubernetes.io/target: external.dcunha.io`.
In the `gateway-httproute` source the **target comes from the Gateway annotation**, and
putting a `target` annotation on the individual HTTPRoute does **not** override it —
verified the hard way 2026-08-19, which published
`echo.frostlink.dev CNAME external.dcunha.io` and shoved the hostname into the Cloudflare
tunnel.

So the frostlink instance watches the CRD source only. Every published hostname is
resolved by the grey `*.frostlink.dev` wildcard CNAME, which is the whole point of the
one-time wildcard design — per-name records are redundant _and_ inherit the wrong target.
If a specific record is ever genuinely needed, add it to the DNSEndpoint.

(The wrong record cleaned itself up: `policy: sync` deleted it once it left the desired
set, because `owner=artemis` matched. Good evidence the ownership split works.)

Publishing an app is therefore just an HTTPRoute with a `frostlink.dev` hostname on
`external-gateway`, and no DNS annotation at all.

### TCP routes by port, not hostname

There is no TLS on a raw TCP service, so no SNI, so the edge routes it **by listen port**.
`mc.frostlink.dev` is just a name resolving to the edge IP; the port is what selects the
service. One port = one server. For several, use SRV records
(`_minecraft._tcp.<name>` -> edge:port) so players can type a bare hostname.

On the **CRD source a `cloudflare-proxied` annotation on the DNSEndpoint object is
ignored** — it must be `providerSpecific` on the endpoint itself.

## Getting an invite token

Issued by the frostlink hub, scoped to the hostnames the agent may claim. From a
session with frostlink access:

```bash
kubectl --context=frostlink -n towonel exec ds/towonel -c main -- cat /data/operator.key > /tmp/opkey
curl -sS -X POST https://hub.frostlink.dev/v1/invites \
  -H "Authorization: Bearer $(cat /tmp/opkey)" -H 'content-type: application/json' \
  -d '{"name":"artemis","hostnames":["*.frostlink.dev"],"tcp_ports":[25565]}'
```

The response's `token` (`tt_inv_2_…`) is the only secret. It **embeds the hub
identity**, so the agent needs no hub URL. Revoke with
`DELETE /v1/invites/{invite_id}`. The frostlink repo's `towonel-ops` skill covers this.

**The 1Password item must be created by the user.** `op item create` into the
`kubernetes` vault returns `(101) You do not have permission` from an agent session.

```bash
op item create --vault kubernetes --category "API Credential" --title towonel \
  "TOWONEL_INVITE_TOKEN[password]=<token>"
```

Then the standard ExternalSecret pattern (`dataFrom.extract.key: towonel`), consumed as
a `secretKeyRef` on the `TOWONEL_INVITE_TOKEN` env var.

The `frostlink.dev` Cloudflare token already exists as the `cloudflare-frostlink` item
in the `kubernetes` vault (see § The collision guard). One token serves both
`frostlink-dns` and cert-manager's DNS-01 solver. It is zone-scoped to `frostlink.dev`
only — not a copy of frostlink's private key. Cloudflare has no TXT-only grant, so it
can edit any record in that zone; that is the accepted floor.

## Shape

`kubernetes/apps/network/towonel-agent/` — `ks.yaml` plus `app/` holding
`ocirepository.yaml`, `externalsecret.yaml`, `helmrelease.yaml`, `dnsendpoint.yaml`.
The second external-dns is a sibling app at
`kubernetes/apps/network/frostlink-dns/`; `towonel-agent` `dependsOn` it.

Because this is app-template, the hardening is written out explicitly rather than
inherited from chart defaults — take these from bjw-s verbatim:
`automountServiceAccountToken: false`, `runAsNonRoot` with uid/gid/fsGroup 10001,
`seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`,
`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`. Health is `/healthz` on
port 9090 for all three probes, with a **60-failure startup budget** (the agent can take
a while to establish the iroh connection) and **`timeoutSeconds: 3` on liveness** —
1 second is too tight and causes spurious restarts.

The agent is stateless — no PVC, no kopiur. All state is the invite token.

**Write the manifests comment-free** — `yaml-conventions.md` forbids prose in
`kubernetes/`. The rationale lives here instead. (The reverted attempt was written in
frostlink's comment-heavy style and would have failed review.)

## PROXY protocol — the one that will bite you

Passthrough services prepend a **HAProxy PROXY protocol v2 header** by default
(`proxy_protocol` defaults to `v2` for `TOWONEL_AGENT_SERVICES`, and `none` for TCP
services). Envoy reads that header as request bytes and drops the connection. Symptoms,
which point away from the real cause:

- client sees `tlsv1 alert protocol version` (alert 70) — looks like a TLS version problem
- agent logs `edge->origin: Broken pipe (os error 32)` and
  `stream error: forwarding ended with a copy error`
- Envoy tested directly (port-forward + `openssl s_client -servername`) works perfectly,
  serving the right cert by SNI

Upstream documents it under "Passthrough behind Envoy / Envoy Gateway". Two ways out:

| Option                             | Cost                                                       |
| ---------------------------------- | ---------------------------------------------------------- |
| `"proxy_protocol":"none"` (in use) | origin sees the **agent's pod IP**, not the real client IP |
| Enable PROXY protocol on Envoy     | needs a **dedicated** Gateway                              |

The second cannot be done on `external-gateway`: it also serves cloudflared and internal
traffic, and neither sends a PROXY header, so enabling it gateway-wide breaks everything
else. Preserving real client IPs means standing up a second Gateway used only by towonel.
Worth doing before anything that needs per-IP rate limiting or meaningful access logs;
not worth it for the first service.

## Beyond HTTPS

`agent.tcpServices[]` and `agent.udpServices[]` tunnel arbitrary ports — erwan carries
Forgejo SSH on 2222 and TURN on 3478/5349. Worth knowing before settling on a hostname
scheme, because it means the tunnel is not limited to web traffic.

## Jellyfin — live on both hostnames since 2026-08-19

Jellyfin is published on **both** `jellyfin.dcunha.io` (cloudflared) and
`jellyfin.frostlink.dev` (towonel) at once. app-template supports multiple named routes,
so it is two route entries against one Service — this is the pattern for dual-publishing
anything:

```yaml
route:
    app:
        hostnames: ["{{ .Release.Name }}.dcunha.io"]
        parentRefs: [{ name: external-gateway, namespace: network }]
    frostlink:
        hostnames: ["{{ .Release.Name }}.frostlink.dev"]
        parentRefs: [{ name: edge-gateway, namespace: network }]
```

Cloudflare's terms forbid serving video over the CDN, so towonel is the **compliant**
path for this, not a downgrade.

**Known and deliberately accepted:** `JELLYFIN_PublishedServerUrl` is pinned to the
`dcunha.io` hostname, so the unauthenticated `/System/Info/Public` endpoint returns
`LocalAddress: https://jellyfin.dcunha.io` to public clients. The user accepted this
2026-08-19: the home IP is not exposed (that name resolves to Cloudflare) and it was
already a public hostname, so the only leak is the correlation between the two names.
The alternative — pointing the published URL at `frostlink.dev` — would make **LAN**
clients hairpin out to the VPS and back, capping local playback at residential upload.
Unsetting it entirely (letting Jellyfin derive per request) is the clean fix if the
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
- **lefthook rewrites `$schema` in `kustomization.yaml`** to
  `k8s-schemas.home-operations.com` (frostlink uses `json.schemastore.org`) and **exits
  1 on the run where it rewrites**. Re-run the commit; never `--no-verify`.
- **Missing UDP fails silently.** frostlink must have UDP 51820 open. If agents reach
  the hub via relay but never go direct, suspect the UDP rule.
- Default relay is whatever the hub advertises (n0's public relays). Set
  `relayUrl` only to override. `directConnect` is for NodePort-based relay-less
  connectivity and is not needed to start.

## Verify

**Half 1 — Minecraft (no TLS, so the clean first test):**

1. `towonel_edge_active_sessions` on the frostlink hub goes 0 → 1.
2. `dig +short mc.frostlink.dev @1.1.1.1` returns frostlink's edge IP, and the record is
   **grey** (an orange record returns a Cloudflare anycast address instead).
3. A Minecraft client connects to `mc.frostlink.dev:25565`.
4. Kill the agent and confirm the hub's alert fires.

**Half 2 — HTTPS:**

5. `curl https://<name>.frostlink.dev` answers, and the cert presented is Artemis's own
   `*.frostlink.dev` — check the issuance date/serial differs from frostlink's own cert.
   A frostlink-issued cert would mean terminate mode, not passthrough.
6. Re-enable `TowonelEdgeNoSessions` in frostlink's `prometheusrule-edge.yaml` — it is
   deliberately omitted while zero agents is the correct steady state.
