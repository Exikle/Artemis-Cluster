# Anubis — Proof-of-Work Scraper Deterrence

Anubis sits in front of an app as a reverse proxy. It makes unrecognized clients solve a
proof-of-work challenge before they reach the backend. It exists to slow AI crawlers that ignore
`robots.txt`. Artemis deploys it in front of `forgejo` (`git.dcunha.io`) and `jelu` (`jelu.dcunha.io`).

Upstream: <https://github.com/TecharoHQ/anubis>

The component here is near-identical to the component of Frostlink. `diff -ru` against
`frostlink/kubernetes/components/anubis/` shows three deltas. Keep the two in sync, and fix a bug in
both. Both read a 1Password item named `anubis`. The store of each cluster resolves its own vault
first, so the two keys never cross.

| Delta                        | Artemis                                      | Frostlink                                            |
| ---------------------------- | -------------------------------------------- | ---------------------------------------------------- |
| Skip-annotation domain       | `anubis.dcunha.io/…`, `postgres.dcunha.io/…` | `anubis.frostlink.dev/…`, `postgres.frostlink.dev/…` |
| `USE_REMOTE_ADDRESS: "true"` | **set** (see § Client IP)                    | absent — Frostlink does not need it                  |
| `$schema` URLs               | `k8s-schemas.home-operations.com`            | `json.schemastore.org`                               |

The `USE_REMOTE_ADDRESS` delta is deliberate. Do **not** sync it to Frostlink, because it would
throw away the real client IPs that Frostlink does get. The other two deltas are cosmetic or
per-cluster.

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

1. Add the workload. `base/` holds the OCIRepository, HelmRelease and ExternalSecret for
   `${APP}-anubis`. Flux builds them inline into the Kustomization of the consuming app, so they
   land in the `targetNamespace` of that app.
2. Re-point the route. A JSON patch swaps `route.app.rules[0].backendRefs` in the HelmRelease of the
   consuming app to `${APP}-anubis:8080`.

The consuming ks needs `APP` and `ANUBIS_TARGET` substitutions, and `onepassword-connect` in
`dependsOn`.

The HelmRelease of the component also carries `postgres.dcunha.io/skip-cert-patch: "true"`, and
`components/postgres/app/patch/` selects on `!postgres.dcunha.io/skip-patch`. Without the
annotation, the postgres component mounts a `postgres-${APP}-anubis-cert` Secret that nobody issues,
and Anubis sits in `Init:0/1` forever. Any future sidecar that you introduce through a component
needs the same annotation. The general rule is that a second workload in the Kustomization of an app
exposes that workload to the patch of every _other_ component.

### Why the skip annotation exists

The route patch targets _all_ HelmReleases in the build, including the HelmRelease of Anubis. The
patch would make Anubis proxy to itself. The patch cannot exclude Anubis by name, because Flux
substitutes `${APP}` at `postBuild` time, _after_ kustomize has run. A `name: ${APP}-anubis` target
matches nothing during the build.

So the HelmRelease of the component carries `anubis.dcunha.io/skip-route-patch: "true"`, and the
patch selects on `annotationSelector: "!anubis.dcunha.io/skip-route-patch"`. That annotation is the
only thing that keeps the patch off Anubis itself. Do **not** remove it.

The patch replaces only `backendRefs`, not the whole `rules` array. If you replace `rules`
wholesale, it silently drops sibling `filters` such as CORS.

Each consuming app ships its own `${APP}-anubis-policy` ConfigMap. The component mounts the
ConfigMap but does not create it. Policies are highly app-specific, which lets the component itself
stay cluster-agnostic.

---

## Forgejo Is Wired Differently

Forgejo is an **ExternalEndpoint**. It runs outside the cluster at `10.10.99.24:3000`, so it has no
HelmRelease and no `route.app` values for the patch of the component to rewrite. The `TARGET` of
Anubis is the in-cluster Service that fronts Forgejo:
`http://forgejo.external-endpoints.svc.cluster.local:3000`, not the raw host address. The
`external-endpoints` machinery owns the mapping to `10.10.99.24`. The patch is a harmless no-op
there, because kustomize treats a target selector that matches zero resources as a no-op.

Only the _workload_ half of the component is used. The ResourceSet that generates the
external-endpoint HTTPRoutes re-points the route instead:

- `templates/resourceset-http.yaml` renders `backendRefs` from `<< inputs.backendName >>` and
  `<< inputs.backendPort >>`, not from `inputs.name` and `inputs.port`.
- `forgejo/inputs.yaml` sets `backendName: forgejo-anubis` and `backendPort: 8080`.
- `truenas/inputs.yaml` is the _only_ other consumer of the `http` template. It sets them to its own
  name and port, so its route does not change.

Every `http`-template provider sets these fields explicitly. The template does not use a sprig
`default`. This is deliberate. You cannot verify a missing-key default locally with confidence. In
contrast, explicit values render deterministically, and `flate` expands ResourceSets during
`just kube render-ks`, so you can check both routes before you apply.

A new `http` external endpoint requires `backendName` and `backendPort`. Without them, its HTTPRoute
renders with an empty backend. The `https` template is untouched.

---

## What Must Not Be Challenged

A lot of automation talks to `git.dcunha.io`. The `forgejo-anubis-policy` ConfigMap allows:

| Path                                                   | Why                                                 |
| ------------------------------------------------------ | --------------------------------------------------- |
| `/info/refs`, `/git-upload-pack`, `/git-receive-pack`  | git HTTP transport — clone, fetch, push             |
| `/info/lfs/`                                           | git LFS                                             |
| `/api/`                                                | `fjo`, Renovate, forgejo MCP tools, Actions runners |
| `/v2/`                                                 | Forgejo container registry                          |
| `/raw/`, `/archive/`, `/releases/download/`, `/media/` | tooling that fetches files rather than API          |
| `/attachments/`                                        | release assets via the API's `browser_download_url` |
| `/user/login`, `/user/oauth2/`, `/login/oauth/`        | Pocket-ID OIDC login flow                           |
| `/assets/`, `/avatars/`, `/repo-avatars/`              | static assets                                       |
| any path with `?go-get=1`                              | `go install` / `go get` resolving module paths      |

The policy also has upstream imports for git clients, docker/OCI clients, and Gitea RSS/Atom feeds.

The git-transport rules are based on **path** on purpose. The upstream `(data)/clients/git.yaml`
import is based on user agent. It also demands an exact set of `Accept`, `Cache-Control`, `Pragma`
and `Accept-Encoding` headers. Any client that does not send all of them falls through to the
challenge. The policy imports both, but the path rules are the reliable half.

`/attachments/` is separate from `/releases/download/` because API clients do not use the link of
the release page. The `forgejo` backend of mise (and anything else that reads the releases API)
downloads each asset from its `/attachments/<uuid>` URL. Before the policy allowed that path, mise
got the challenge page instead of the archive. It then failed with a checksum mismatch that changed
on every try. Forgejo still enforces repository permissions on attachments, so the files of a
private repository stay private.

The `go-get` rule matches on the query alone, not on the user agent. The `go` command sends
`GoCommand/1 (+https://go.dev/cmd/go)`, not the `Go-http-client/` that the example rule of upstream
expects. Public module proxies send their own user agents. A `?go-get=1` request gets the minimal
`go-import` meta page of Forgejo, not repo content, so a crawler gains nothing by adding it.

Anubis challenges everything else: repo browsing, `/commits/`, `/blame/`, `/issues/`, and
`/explore`. AI crawlers hammer exactly that surface on a git forge.

### GitOps is not at risk

This looks alarming, so the document states it explicitly: Flux does not clone `git.dcunha.io`.
Both clusters sync from an OCI registry. Artemis syncs from `oci://registry.dcunha.io/exikle/artemis-cluster`
and Frostlink syncs from `oci://registry.frostlink.dev/exikle/frostlink`. `apoci` serves both, not
Forgejo. Anubis on `git.dcunha.io` cannot break cluster reconciliation.

### LAN traffic is challenged too

The forgejo HTTPRoute attaches to `edge-gateway` only, on listener `https-dcunha` (set in the
`gateways` of the `forgejo` ResourceSetInputProvider). On the LAN, `git.dcunha.io` resolves to the
IP of that gateway (`10.10.99.90`). LAN browsers therefore arrive through the same gateway as public
traffic, and Anubis challenges them like anyone else. If that becomes annoying, split the route
rather than weaken the policy. But see the note at the end of the next section on why splitting is
awkward.

---

## Client IP — why `USE_REMOTE_ADDRESS` is set

Anubis resolves the client IP from `X-Real-Ip`. If it cannot, it **fails closed with HTTP 500
`[misconfiguration] X-Real-Ip header is not set`**. The Envoy of Artemis sends only
`X-Forwarded-For`, `X-Forwarded-Proto` and `X-Request-Id` upstream. It sends no `x-real-ip` and no
`x-envoy-external-address`. To verify this at any time, run `curl -sS https://echo.dcunha.io/`.

Anubis derives `X-Real-Ip` from XFF. This works for external traffic (public client IP) but not for
LAN clients. `git.dcunha.io` resolves to a gateway VIP on 10.10.99.x, so a LAN browser arrives with
a single RFC1918 address. `xff.Parse` returns only the first **non-private** entry, which here is
nothing. That 500s every allowed route for anyone on the LAN. This is a property of the client being
on the LAN, not of the gateway that the client lands on. On `edge-gateway`, `ClientTrafficPolicy/edge`
sets no `clientIPDetection`. The client address comes from PROXY protocol (`optional: true`). Public
requests arrive through towonel with a v2 header that carries the real client IP, and Envoy appends
that IP to XFF. LAN requests hit `10.10.99.90` with no header, and Envoy appends the LAN address.

Two fixes look plausible but are wrong:

- `XFF_STRIP_PRIVATE=false`: `XForwardedForUpdate` runs with `Flatten: true`, which keeps only the
  **last** surviving entry of `[client..., remoteAddr]`. If Anubis stops stripping private
  addresses, the last entry becomes the own pod IP of Envoy. _Every_ client, external clients
  included, then collapses onto that IP. This is strictly worse than doing nothing.
- `CUSTOM_REAL_IP_HEADER: X-Forwarded-For`: it copies the header verbatim with no filtering. But it
  is the innermost middleware, and `XForwardedForUpdate` has already deleted the all-private XFF by
  then.

So `USE_REMOTE_ADDRESS: "true"` is set. Anubis takes the TCP peer address, which is always present.

The trade-off: Anubis attributes every client to the Envoy pod IP (`10.42.x.x`), so per-client IP
identity is lost. That costs nothing today. DNSBL is off. The ASN/GeoIP weighting in
`default-config.yaml` needs a Thoth subscription that is not configured. The rules that actually
fire (`ai-block-*`, weight 10) match on user agent. The trade-off does weaken
`jwt-restriction-header`, which by default pins a challenge JWT to `X-Real-IP`. With one shared
value, that check is a no-op.

If you ever need per-client IPs, the upgrade path is an **`EnvoyPatchPolicy`** that sets `x-real-ip`
from `%REQ(X-FORWARDED-FOR)%`. `enableEnvoyPatchPolicy: true` is already on. The cluster does not
use this path, because it patches xDS on the shared gateway, and `edge-gateway` carries every public
route on Artemis.

The cluster also rejected a split of the route so that only the public gateway goes through Anubis.
`unifi-dns` has no `--gateway-name` filter and watches every HTTPRoute. Two routes that share
`git.dcunha.io` would race to own the internal A record.

---

## How Effective Is This, Really?

Anubis raises the cost for low-effort crawlers. It does not stop a determined crawler.
[pow-buster](https://github.com/eternal-flame-AD/pow-buster) is a SIMD PoW solver with explicit
Anubis coverage. GoToSocial removed its own comparable PoW middleware in September 2025, partly
because of that solver. Treat Anubis as a rate-limiting speed bump, not a wall.

---

## Operational Notes

- Store: The store is in-memory. No `store` block is configured, so challenge state is lost on
  restart and users re-solve once. If you want persistence, add `store.backend: valkey` that points
  at `redis://dragonfly.database.svc.cluster.local:6379/<db>`. Claim `<db>` from the allocation
  table in `.agents/references/postgres-dragonfly.md` § Onboarding an app onto shared Dragonfly, and
  add a row for it. If you pick an index freehand, it collides with an existing app.
- Difficulty: The policy sets difficulty per rule, not through the `DIFFICULTY` env var. `postBuild`
  substitution yields a bare integer, and container env values must be strings.
- Key material: It comes from the 1Password item `artemis/anubis`, field `ED25519_PRIVATE_KEY_HEX`.
  Rotating the key invalidates outstanding challenge cookies, and users re-solve.
- `OG_PASSTHROUGH`: It is set so that OpenGraph link previews survive. Do not remove it.
- Metrics: Metrics are on port 9090. The `serviceMonitor` of the component scrapes them.

## Off-network failure on iOS

An iPhone on cellular, away from home, hit an error when it loaded `git.dcunha.io`. Nobody
reproduced the error. It is tracked in [#2766](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2766),
and this document keeps it so that a second occurrence can be matched against it. At the time, the
backend, the `forgejo-anubis` pod and the public path were all healthy, and the request of the phone
got a challenge normally. So the fault was **not** connectivity, DNS, IPv6 routing or TLS. Two
`proxy error: context canceled` entries followed, which means the connection went away mid-request.

Leading hypothesis: iCloud Private Relay. The `x-forwarded-for` of the phone was in Cloudflare
address space, not in a carrier range. On iOS off wifi, that usually means Private Relay. Anubis
binds a challenge to the client, and Private Relay rotates egress addresses. If the address changes
between the moment Anubis _issues_ the challenge and the moment the client _submits_ the
proof-of-work, Anubis rejects the solution. That would show only off the home network.

First things to check on a recurrence:

1. Read the exact error text. "Can't connect", a 5xx, and an Anubis page that loops are three
   different faults.
2. Retry with Private Relay disabled (Settings → Apple Account → iCloud → Private Relay). If that
   fixes it, the hypothesis is confirmed and the fix is a policy rule.

Ruled out: The steady trickle of `client was given a challenge but does not in fact support
gzip compression` errors comes from scraper user agents, never from iOS.
