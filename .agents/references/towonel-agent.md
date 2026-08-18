# towonel Agent — Handoff

Plan for publishing Artemis services through the **towonel** tunnel running on
frostlink. Written 2026-08-18. **Not deployed yet** — a working version was built
and verified up to the secret step on 2026-08-18, then reverted to keep that day
scoped to frostlink. Everything below is what that attempt established, so this is
a plan with the unknowns already burned out of it.

Upstream: <https://codeberg.org/towonel/towonel> · chart
`oci://codeberg.org/towonel/charts/towonel-agent` (1.5.3)

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

Point the agent at **this cluster's own gateway**:

```yaml
agent:
    services:
        - hostname: <name>.dcunha.io
          origin: external-gateway.network.svc.cluster.local:443
```

Two things follow, and both matter:

1. **Publishing more hostnames later is just a normal HTTPRoute.** The towonel config
   is a one-time change; everything after routes through `external-gateway` as usual.
2. **The `*.dcunha.io` key never leaves Artemis.** `external-gateway` already holds it
   (`network/dcunha-io-tls`), and passthrough means that cert is what clients actually
   validate. frostlink never sees it.

Point 2 is worth defending. The written S8 brief suggested pulling frostlink's
`*.frostlink.dev` cert from 1Password onto Artemis. That works, but passthrough exists
precisely so a compromised VPS cannot read this cluster's traffic — copying a shared
wildcard key across both clusters gives some of that back. Using a `dcunha.io`
hostname with Artemis's own cert avoids the trade entirely. **Prefer it.**

## The two DNS overrides — both are required

`dcunha.io` has a **wildcard proxied record**: a random subdomain resolves to
`172.64.80.1`. (frostlink.dev does _not_ — do not carry assumptions between them.)
So a towonel hostname needs an explicit record that beats the wildcard, and the
gateway's own DNS automation has to be told to stay out of the way.

**1. Stop external-dns publishing the HTTPRoute.** `external-gateway` carries
`external-dns.alpha.kubernetes.io/target: external.dcunha.io`, so the
`gateway-httproute` source would publish a **proxied CNAME to the Cloudflare tunnel**
— which terminates TLS and cannot forward an SNI-routed stream. Annotate the route:

```yaml
external-dns.alpha.kubernetes.io/controller: none
```

Use a **dedicated** HTTPRoute for the tunnelled hostname. Do not add the hostname to
an existing app's route — that annotation would suppress DNS for its other hostnames
too.

**2. Publish a DNS-only A record at frostlink's edge.** external-dns runs with a
global `--cloudflare-proxied` here, so it needs a per-record override. On the **CRD
source an annotation on the DNSEndpoint object is ignored** — it must be
`providerSpecific` on the endpoint:

```yaml
- dnsName: <name>.dcunha.io
  recordType: A
  targets: ["40.233.88.33"]
  providerSpecific:
      - name: external-dns.alpha.kubernetes.io/cloudflare-proxied
        value: "false"
```

`40.233.88.33` is frostlink's public IP. Verified working on both clusters.

## Getting an invite token

Issued by the frostlink hub, scoped to the hostnames the agent may claim. From a
session with frostlink access:

```bash
kubectl --context=frostlink -n towonel exec ds/towonel -c main -- cat /data/operator.key > /tmp/opkey
curl -sS -X POST https://hub.frostlink.dev/v1/invites \
  -H "Authorization: Bearer $(cat /tmp/opkey)" -H 'content-type: application/json' \
  -d '{"name":"artemis","hostnames":["<name>.dcunha.io"]}'
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

Then the standard ExternalSecret pattern (`dataFrom.extract.key: towonel`) with
`agent.inviteTokenSecret: {name: towonel-agent, key: TOWONEL_INVITE_TOKEN}`.

## Shape

`kubernetes/apps/network/towonel-agent/` — `ks.yaml` plus `app/` holding
`ocirepository.yaml`, `externalsecret.yaml`, `helmrelease.yaml`, `httproute.yaml`,
`dnsendpoint.yaml`.

Chart defaults are already right for Artemis: `replicas: 2`, RollingUpdate,
non-root uid/gid 10001, read-only rootfs, no ServiceAccount token mounted. Enable
`serviceMonitor.main`, `monitoring.prometheusRule`, and the dashboard via
`monitoring.dashboards.grafanaOperator` with `matchLabels: {dashboards: grafana}`.

**Write the manifests comment-free** — `yaml-conventions.md` forbids prose in
`kubernetes/`. The rationale lives here instead. (The reverted attempt was written in
frostlink's comment-heavy style and would have failed review.)

## Beyond HTTPS

`agent.tcpServices[]` and `agent.udpServices[]` tunnel arbitrary ports — erwan carries
Forgejo SSH on 2222 and TURN on 3478/5349. Worth knowing before settling on a hostname
scheme, because it means the tunnel is not limited to web traffic.

## Jellyfin, later

Viable but deliberately **not** the first service. Cloudflare's terms forbid serving
video over the CDN, so towonel is the compliant path rather than a downgrade. OCI
Always Free gives 10 TB/month egress; Artemis→frostlink is VPS _ingress_ and
uncounted, so each delivered byte counts once. The real ceiling is Artemis's
residential **upload** (~20–50 Mbps), not the VPS. Add an egress alert around 7 TB
and expect seeking to feel worse than direct play.

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
- The agent is stateless — no PVC, no kopiur. All state is the invite token.

## Verify

1. `towonel_edge_active_sessions` on the frostlink hub goes 0 → 1.
2. `curl https://<name>.dcunha.io` answers, and the cert presented is `*.dcunha.io`
   (proving passthrough — a frostlink-issued cert would mean terminate mode).
3. Kill the agent and confirm the hub's alert fires.
4. Re-enable `TowonelEdgeNoSessions` in frostlink's `prometheusrule-edge.yaml` — it is
   deliberately omitted while zero agents is the correct steady state.
