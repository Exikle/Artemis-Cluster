# towonel Agent — Artemis-Cluster

This file explains how Artemis is reached from the public internet. The decision and its history are
in issue #3082. The frostlink side is documented in the frostlink repo: its towonel reference and
its networking reference (§ The front door).

## What the agent does (Shape 1)

Artemis publishes no hostname through towonel. frostlink's Envoy terminates TLS for every public
name, runs CrowdSec, and re-encrypts to Artemis over one towonel TCP service.

| Part           | Value                                                                |
| -------------- | -------------------------------------------------------------------- |
| Service name   | `artemis-backhaul`                                                   |
| Edge port      | `15001`                                                              |
| Origin         | `edge-gateway.network.svc.cluster.local:443`                         |
| Defined in     | `TOWONEL_AGENT_TCP_SERVICES` in `towonel-agent/app/helmrelease.yaml` |
| frostlink side | the `home-backhaul` app in frostlink's `towonel` namespace           |

The agent dials out over iroh QUIC (UDP 51820 on frostlink) and holds the connection open. Artemis
opens no inbound port.

- **No hostname claims.** The agent has no `TOWONEL_AGENT_SERVICES`. frostlink sends all of
  `*.dcunha.io` and `dcunha.io` to the backhaul.
- **No PROXY protocol.** The backhaul carries HTTPS that Envoy re-encrypts. The real client IP is in
  `X-Forwarded-For`, which frostlink's Envoy sets.
- **`ClientTrafficPolicy/edge` must trust that header.** It trusts `X-Forwarded-For` from
  `10.42.0.0/16`, the agent pod CIDR. Without it, every request looks like it comes from the agent
  and the per-IP rate limits rate-limit everyone at once.
- **No CrowdSec on Artemis.** A `403` or challenge page on a public site is frostlink's CrowdSec.
  Fix it in the frostlink repo (`crowdsec.md`). LAN traffic is not checked.
- **SNI on the backhaul.** frostlink validates the Artemis certificate with SNI `edge.dcunha.io`,
  and with `dcunha.io` for the apex, because `edge-gateway` has a separate apex listener.

The agent is app-template (`codeberg.org/towonel/towonel-agent` image), not the upstream chart.
Configuration is `TOWONEL_AGENT_*` environment variables. Versions: `grep -h 'tag:'
kubernetes/apps/network/towonel-agent/app/*.yaml`.

Repo boundary: frostlink and Artemis stay separate repos. The interface is one invite token and the
backhaul port. Do not share manifests or components. Do not propose a monorepo.

## Which gateway a route uses

`edge-gateway` is the list of **public** Artemis apps. Public hostnames, and LAN DNS (`10.10.99.90`,
LAN name `edge.dcunha.io`), both reach it. Never point the backhaul at `internal-gateway`.

| Hostname                | `parentRefs`       | `sectionName`           |
| ----------------------- | ------------------ | ----------------------- |
| `*.dcunha.io`, public   | `edge-gateway`     | `https-dcunha`, or none |
| `dcunha.io` apex        | `edge-gateway`     | `https-dcunha-apex`     |
| `*.dcunha.io`, LAN only | `internal-gateway` | `https`, or none        |

`external-gateway` takes no new routes.

The `sectionName: https` trap: on `internal-gateway` and `external-gateway`, `https` is the
`dcunha.io` listener. On `edge-gateway` it is the `frostlink.dev` listener, so a `*.dcunha.io` route
that pins `sectionName: https` never attaches. Use `https-dcunha`. Auth SecurityPolicies (tinyauth,
envoy-oidc) target the HTTPRoute, so they follow the route.

## Certificates

Public visitors see frostlink's certificate. Artemis certificates are seen only over the backhaul
(frostlink checks them) and by LAN clients. A certificate problem on a public name is therefore
frostlink's, unless the backhaul check fails.

`frostlink-dev-tls` in `network` is imported from 1Password, not issued here. Copy the shape from
`certificates/import/frostlink-externalsecret.yaml`, **not** from the neighboring
`externalsecret.yaml`. The frostlink import keeps the ExternalSecret defaults (`refreshInterval` 1h,
`creationPolicy: Owner`), so it picks up renewals. The `dcunha-io-tls` import is bootstrap-only
(`refreshPolicy: CreatedOnce`, `creationPolicy: Orphan`) and cert-manager owns its renewal. Copying
that pattern onto the frostlink import would serve an expired certificate at the next rollover.
cert-manager does not manage the imported secret, so its expiry metrics do not cover it.

## DNS

Records for the public names are **grey** and point at `edge.frostlink.dev`. frostlink's Envoy
answers there. A proxied record sends the connection to Cloudflare instead.

- **dcunha.io:** `external-dns-edge` (`kubernetes/apps/network/edge-dns/`) writes a grey CNAME per
  `edge-gateway` route. It reads only `edge-dns.kubernetes.io/` annotations (`--annotation-prefix`),
  so `external-dns-unifi` can keep the standard `external-dns.kubernetes.io/target:
  edge.dcunha.io` for the LAN. Settings: `kubectl get deploy -n network external-dns-edge -o
  yaml --context artemis`.
- **status.dcunha.io:** a grey CNAME to `edge.frostlink.dev`, from
  `cloudflare-dns/app/dnsendpoint.yaml`. It is served by Envoy on frostlink.
- **edge.dcunha.io:** a grey CNAME to `edge.frostlink.dev`, from
  `towonel-agent/app/dnsendpoint.yaml`. It exists for IPv6 LAN clients (`networking.md` § The
  LAN-side AAAA leak).
- **frostlink.dev:** Artemis no longer publishes a `*.frostlink.dev` wildcard (removed 2026-11-12).
  frostlink owns its own records. `external-dns-frostlink` (`network/frostlink-dns`) still runs with
  `crd` as its only source.
- **Specific names on a `DNSEndpoint`:** an annotation on the DNSEndpoint object is ignored. Set
  `cloudflare-proxied: "false"` as `providerSpecific` on the endpoint.
- **Check with `@1.1.1.1`.** Bare `dig` on the dev machine returns the split-horizon (LAN) answer.

### The collision guard

frostlink's external-dns runs `policy: sync` with `txtOwnerId: frostlink` over the `frostlink.dev`
zone. A second controller on that zone must differ in **both** owner id and TXT prefix, or the two
delete each other's records in a loop:

```yaml
txtOwnerId: artemis # not frostlink
txtPrefix: k8s.artemis.%{record_type}- # not frostlink's prefix
```

The owner id decides what a controller deletes. The prefix decides whether it can see the other
controller's ownership TXT records. Matching prefixes with different owner ids is the loop, because
the controllers overwrite each other's registry entries. frostlink's `external-dns-cloudflare`
uses `k8s.%{record_type}-`, which is the same prefix as Artemis's own `external-dns-cloudflare`
(owner `artemis-cluster`). Omit `--cloudflare-proxied` on the frostlink-zone instance so records
default to grey.

## Getting an invite token

The frostlink hub issues the token. Run this from a session with frostlink access:

```bash
kubectl --context=frostlink -n towonel exec ds/towonel -c main -- cat /data/operator.key > /tmp/opkey
curl -sS -X POST https://hub.frostlink.dev/v1/invites \
  -H "Authorization: Bearer $(cat /tmp/opkey)" -H 'content-type: application/json' \
  -d '{"name":"artemis","hostnames":[],"tcp_ports":[15001]}'
```

**The invite carries the port grant, not the agent config.** Without `tcp_ports` for 15001, the edge
declines to bind the listener and neither side logs an error. The `towonel invite create --help`
output in the frostlink pod has the exact flags, and the `towonel-ops` skill in the frostlink repo
covers the call. Check the request body above against them before use.

The `token` (`tt_inv_2_…`) in the response is the only secret. It embeds the hub identity, so the
agent needs no hub URL. Revoke it with `DELETE /v1/invites/{invite_id}`.

The user must create the 1Password item (`op item create` from an agent session returns `(101) You
do not have permission`). It lives in the `artemis` vault, in item `towonel`, field
`TOWONEL_INVITE_TOKEN`. The ExternalSecret is inline under `externalSecrets.env` in the HelmRelease
(`dataFrom.extract.key: towonel`), and the agent reads it as a `secretKeyRef` on `TOWONEL_INVITE_TOKEN`.

## Shape

`kubernetes/apps/network/towonel-agent/` holds `ks.yaml` plus `app/` with `ocirepository.yaml`,
`helmrelease.yaml` and `dnsendpoint.yaml`. The agent is stateless: no PVC, no kopiur. All state is
the invite token.

app-template does not inherit chart hardening, so it is written out in the HelmRelease. Health is
`/healthz` on port 9090, with a 60-failure startup budget (the agent can take a while to establish
the iroh connection) and `timeoutSeconds: 3` on liveness. A 1 s timeout is too tight and causes
spurious restarts. Write the manifests comment-free (`yaml-conventions.md`).

**Memory is sized for bursts, not idle.** The agent idles near 25–50Mi, but it buffers every stream
it relays. apoci federation opens one download per layer (2–3 per digest) when a peer pushes an
image. A ~10-layer image drove the agent past an old 128Mi limit. Each OOM restart dropped every
public connection for a few seconds, and frostlink's apoci logged `eager replication failed … EOF`
for every in-flight blob. At 512Mi, a 19-blob, ~400MB parallel pull ran clean (2026-10-27). If it
OOMs again, raise the limit. Do not throttle apoci: its replication concurrency is not configurable.
Since Shape 1, **all** public traffic crosses this one agent, so an OOM now drops every public
Artemis connection.

## Other TCP and UDP services

`TOWONEL_AGENT_TCP_SERVICES` holds only `artemis-backhaul`. `minecraft` (25565/tcp) and `eco`
(3000/udp) were removed earlier, because both apps are commented out of `arcade/kustomization.yaml`
and the open ports only drew scanners. To re-add one, the entry shape is
`{"name":"<name>","origin":"<service>.<namespace>.svc.cluster.local:<port>","listen_port":<port>}`
(UDP entries also take `idle_timeout_secs` and use `TOWONEL_AGENT_UDP_SERVICES`).

- It bypasses `edge-gateway`: the agent dials the app Service directly.
- The edge binds the host port only while an agent session exists, so a port test proves nothing
  while the agent is down.
- The invite must grant the port, and the OCI security list on frostlink must allow it.

## Jellyfin — the video path

`jellyfin.dcunha.io` is served through frostlink's Envoy and the backhaul. The Cloudflare terms
forbid serving video over the CDN, and every record is grey, so no Jellyfin traffic touches
Cloudflare.

`jellyfin_compat.public_url` of silo is pinned to the `dcunha.io` hostname, so the unauthenticated
`/System/Info/Public` endpoint returns `LocalAddress: https://jellyfin.dcunha.io` to public clients.
The home IP is not exposed. Accepted. Pointing the URL at another hostname would make LAN clients
hairpin out to the VPS and cap local playback at residential upload.

**Bandwidth.** OCI Always Free gives 10 TB/month egress. Artemis to frostlink is VPS ingress and is
uncounted, so each delivered byte counts once. The real ceiling is Artemis's residential upload
(about 20–50 Mbps). Expect seeking to feel worse than direct play.

## Gotchas

- Missing UDP fails silently. frostlink must have UDP 51820 open. If agents reach the hub by relay
  but never go direct, suspect the UDP rule.
- The default relay is whatever the hub advertises. Set `relayUrl` only to override it.
- The pre-commit hook rewrites `$schema` in `kustomization.yaml` to `k8s-schemas.home-operations.com`
  (frostlink uses `json.schemastore.org`) and stages the rewrite. Never use `--no-verify`.
- If the agent is down, frostlink's `home-down` page answers `503` for every `dcunha.io` name.

## Verify

1. `towonel_edge_active_sessions` on the frostlink hub is at least 1 while the agent runs.
2. frostlink's `TowonelEdgeNoSessions` alert (`app/prometheusrule-edge.yaml`) is on. It is the only
   alert for a dead tunnel. Leave it on.
3. `curl -sI https://<name>.dcunha.io` from outside answers, and the certificate is frostlink's.
