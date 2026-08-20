# Anubis — Proof-of-Work Scraper Deterrence

Anubis sits in front of an app as a reverse proxy and makes unrecognised clients solve a
proof-of-work challenge before reaching the backend. It exists to slow AI crawlers that ignore
`robots.txt`. Deployed on Artemis in front of `forgejo` (`git.dcunha.io`) only.

Upstream: <https://github.com/TecharoHQ/anubis>

The component here is byte-identical to Frostlink's apart from the 1Password item name and the
skip annotation domain. Keep the two in sync — fix a bug in both.

---

## Component Shape

`kubernetes/components/anubis/` is a flat kustomize Component with two jobs:

```text
components/anubis/
├── kustomization.yaml     # Component — pulls in ./base, applies the route patch
└── base/
    ├── kustomization.yaml
    ├── externalsecret.yaml
    ├── helmrelease.yaml
    └── ocirepository.yaml
```

1. **Add the workload.** `base/` holds the OCIRepository, HelmRelease and ExternalSecret for
   `${APP}-anubis`, built inline into the consuming app's Kustomization so they land in that
   app's `targetNamespace`.
2. **Re-point the route.** A JSON patch swaps `route.app.rules[0].backendRefs` in the consuming
   app's HelmRelease to `${APP}-anubis:8080`.

The consuming ks needs `APP` and `ANUBIS_TARGET` substitutions, plus `onepassword-connect` in
`dependsOn`.

### Why the skip annotation exists

The route patch targets _all_ HelmReleases in the build — including Anubis's own, which would make
it proxy to itself. It cannot exclude Anubis by name, because `${APP}` is substituted by Flux at
`postBuild` time, _after_ kustomize has run, so a `name: ${APP}-anubis` target matches nothing
during the build.

So the component's own HelmRelease carries `anubis.dcunha.io/skip-route-patch: "true"`, and the
patch selects on `annotationSelector: "!anubis.dcunha.io/skip-route-patch"`. That annotation is
the only thing keeping the patch off Anubis itself — **do not remove it.**

The patch replaces only `backendRefs`, not the whole `rules` array — replacing `rules` wholesale
silently drops sibling `filters` such as CORS.

Each consuming app ships its own `${APP}-anubis-policy` ConfigMap; the component mounts it but
does not create it. Policies are highly app-specific, which is what lets the component itself stay
cluster-agnostic.

---

## Forgejo Is Wired Differently

Forgejo is an **ExternalEndpoint** (it runs outside the cluster at `10.10.99.24:3000`), so it has
no HelmRelease and no `route.app` values for the component's patch to rewrite. The patch is a
harmless no-op there — kustomize treats a target selector matching zero resources as a no-op.

Only the _workload_ half of the component is used. The route is re-pointed instead through the
ResourceSet that generates external-endpoint HTTPRoutes:

- `templates/resourceset-http.yaml` renders `backendRefs` from `<< inputs.backendName >>` and
  `<< inputs.backendPort >>` rather than `inputs.name` / `inputs.port`.
- `forgejo/inputs.yaml` sets `backendName: forgejo-anubis`, `backendPort: 8080`.
- `truenas/inputs.yaml` — the _only_ other consumer of the `http` template — sets them to its own
  name and port, leaving its route unchanged.

These fields are set explicitly on every `http`-template provider rather than defaulted with a
sprig `default` in the template. That is deliberate: a missing-key default cannot be verified
locally with confidence, whereas explicit values render deterministically and `flate` expands
ResourceSets during `just kube render-local-ks`, so both routes are checkable before applying.

**Adding a new `http` external endpoint requires setting `backendName` and `backendPort`**, or its
HTTPRoute will render with an empty backend. The `https` template is untouched.

---

## What Must Not Be Challenged

A lot of automation talks to `git.dcunha.io`. The `forgejo-anubis-policy` ConfigMap allows:

| Path                                                   | Why                                                 |
| ------------------------------------------------------ | --------------------------------------------------- |
| `/info/refs`, `/git-upload-pack`, `/git-receive-pack`  | git HTTP transport — clone, fetch, push             |
| `/info/lfs/`                                           | git LFS                                             |
| `/api/`                                                | `tea`, Renovate, forgejo MCP tools, Actions runners |
| `/v2/`                                                 | Forgejo container registry                          |
| `/raw/`, `/archive/`, `/releases/download/`, `/media/` | tooling that fetches files rather than API          |
| `/user/login`, `/user/oauth2/`, `/login/oauth/`        | Pocket-ID OIDC login flow                           |
| `/assets/`, `/avatars/`, `/repo-avatars/`              | static assets                                       |

Plus upstream imports for git clients, docker/OCI clients, and Gitea RSS/Atom feeds.

The git-transport rules are **path**-based on purpose. The upstream `(data)/clients/git.yaml`
import is user-agent based and additionally demands an exact set of `Accept`, `Cache-Control`,
`Pragma` and `Accept-Encoding` headers — any client that does not send all of them falls through
to the challenge. Both are imported; the path rules are the reliable half.

Everything else — repo browsing, `/commits/`, `/blame/`, `/issues/`, `/explore` — is challenged.
That is the surface AI crawlers actually hammer on a git forge.

### GitOps is not at risk

Worth stating explicitly because it looks alarming: **Flux does not clone `git.dcunha.io`.** Both
clusters sync from an OCI registry — Artemis from `oci://registry.dcunha.io/exikle/artemis-cluster`
and Frostlink from `oci://registry.frostlink.dev/exikle/frostlink`, both served by `apoci`, not by
Forgejo. Anubis on `git.dcunha.io` cannot break cluster reconciliation.

### Both gateways are affected

The forgejo HTTPRoute has `external-gateway` _and_ `internal-gateway` parentRefs, and there is one
route for both. Internal browser traffic gets challenged too. If that becomes annoying, split the
route rather than weakening the policy.

---

## Client IP — why `USE_REMOTE_ADDRESS` is set

Anubis resolves the client IP from `X-Real-Ip` and **fails closed with HTTP 500
`[misconfiguration] X-Real-Ip header is not set`** if it cannot. Artemis's Envoy sends only
`X-Forwarded-For`, `X-Forwarded-Proto` and `X-Request-Id` upstream — no `x-real-ip` and no
`x-envoy-external-address`. Verify any time with `curl -sS https://echo.dcunha.io/`.

Anubis derives `X-Real-Ip` from XFF, which works for external traffic (public client IP) but not
for the internal path: `git.dcunha.io` also resolves to `internal-gateway`, so LAN clients arrive
with a single RFC1918 address and `xff.Parse` returns only the first **non-private** entry —
nothing. That 500s every allowed route for anyone on the LAN.

Two fixes that look plausible but are wrong:

- **`XFF_STRIP_PRIVATE=false`** — `XForwardedForUpdate` runs with `Flatten: true`, which keeps only
  the **last** surviving entry of `[client..., remoteAddr]`. Stop stripping private addresses and
  the last entry becomes Envoy's own pod IP, so _every_ client, external included, collapses onto
  it. Strictly worse than doing nothing.
- **`CUSTOM_REAL_IP_HEADER: X-Forwarded-For`** — it copies verbatim with no filtering, but it is the
  innermost middleware and `XForwardedForUpdate` has already deleted the all-private XFF by then.

So `USE_REMOTE_ADDRESS: "true"` is set: Anubis takes the TCP peer address, which is always present.

**The trade-off:** every client is attributed to the Envoy pod IP (`10.42.x.x`), so per-client IP
identity is lost. That costs nothing today — DNSBL is off, and the ASN/GeoIP weighting in
`default-config.yaml` needs a Thoth subscription that is not configured, so the rules that actually
fire (`ai-block-*`, weight 10) match on user-agent. It does weaken `jwt-restriction-header`, which
by default pins a challenge JWT to `X-Real-IP`; with one shared value that check is a no-op.

The upgrade path, if per-client IPs are ever needed, is an **`EnvoyPatchPolicy`** setting
`x-real-ip` from `%REQ(X-FORWARDED-FOR)%` — `enableEnvoyPatchPolicy: true` is already on. It was
not used here because it patches xDS on the shared gateway, which carries ~20 other routes.

Splitting the route so only `external-gateway` goes through Anubis was also rejected: `unifi-dns`
has no `--gateway-name` filter and watches every HTTPRoute, so two routes sharing `git.dcunha.io`
would race to own the internal A record.

---

## How Effective Is This, Really?

Anubis raises the cost for low-effort crawlers; it does not stop a determined one.
[pow-buster](https://github.com/eternal-flame-AD/pow-buster) is a SIMD PoW solver with explicit
Anubis coverage, and GoToSocial removed its own comparable PoW middleware in September 2025 partly
because of it. Treat Anubis as a rate-limiting speed bump, not a wall.

---

## Operational Notes

- **Store is in-memory.** No `store` block is configured, so challenge state is lost on restart and
  users re-solve once. Add `store.backend: valkey` pointing at
  `redis://dragonfly.database.svc.cluster.local:6379/<db>` if persistence is wanted.
- **Difficulty is set per-rule in the policy**, not via the `DIFFICULTY` env var — `postBuild`
  substitution yields a bare integer and container env values must be strings.
- **Key material** comes from the 1Password item `anubis-artemis`, field
  `ED25519_PRIVATE_KEY_HEX`. Rotating it invalidates outstanding challenge cookies; users re-solve.
- **`OG_PASSTHROUGH`** is set so OpenGraph link previews survive. Do not remove it.
- **Metrics** on port 9090, scraped via the component's `serviceMonitor`.

## Open incident — off-network failure on iOS (2026-08-19)

The user hit an error loading `git.dcunha.io` from an **iPhone on cellular, away from
home**. Not reproduced; noted here so a second occurrence can be matched against it
rather than re-investigated from scratch.

**Everything checked out healthy at the time:**

| Check                                    | Result                          |
| ---------------------------------------- | ------------------------------- |
| `forgejo-anubis` pod                     | 0 restarts, 22m CPU, 29Mi       |
| Forgejo backend `10.10.99.24:3000`       | HTTP 200 in 2.6 ms              |
| External path (forced via Cloudflare IP) | HTTP 200, challenge page served |
| `ClientTrafficPolicy` on both gateways   | `Accepted=True`                 |

**The phone reached the server.** At 18:47:53 the log shows an iPhone iOS 18.7 /
Safari 26.6 / `en-CA` request issued a challenge normally — so this was **not**
connectivity, DNS, IPv6 routing or TLS. Two `proxy error: context canceled` follow at
18:48:04–05, meaning the connection went away mid-request.

**Leading hypothesis: iCloud Private Relay.** The phone's `x-forwarded-for` was
`2a09:bac2:18c3:2be::46:103` — Cloudflare address space, not a carrier range, which on
iOS off-wifi usually means Private Relay. Anubis binds a challenge to the client, and
Private Relay rotates egress addresses; if the address changes between the challenge
being _issued_ and the proof-of-work being _submitted_, the solution is rejected. That
would manifest only off the home network, which matches.

**First things to check on a recurrence:**

1. The exact error text — "can't connect" vs a 5xx vs Anubis's own page looping are
   three different faults.
2. Retry with Private Relay disabled (Settings → Apple Account → iCloud → Private Relay).
   If that fixes it, the hypothesis is confirmed and the fix is a policy rule.

**Ruled out:** the 44/day `client was given a challenge but does not in fact support gzip
compression` errors are **all** scraper user-agents (Firefox 135 / Chrome 99 on Mac and
Windows), never iOS. Background noise against 2727 challenges/day, not this.
