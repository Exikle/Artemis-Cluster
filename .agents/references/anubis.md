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

## OPEN BLOCKER — `X-Real-Ip` on the internal path

**The Forgejo route is currently NOT going through Anubis.** The workload is deployed and healthy
in `external-endpoints`, but `forgejo/inputs.yaml` still has `backendName: forgejo` /
`backendPort: 3000`. Flipping it to `forgejo-anubis` / `8080` currently breaks `git.dcunha.io`
with HTTP 500 on every allowed route.

Cause: Anubis resolves the client IP from the `X-Real-Ip` header and fails closed with
`[misconfiguration] X-Real-Ip header is not set`. It will derive it from `X-Forwarded-For`, but
`xff.Parse` returns the first **non-private** address — and `git.dcunha.io` resolves internally to
`internal-gateway`, so LAN clients arrive with an all-RFC1918 XFF chain and nothing is resolved.
`XFF_STRIP_PRIVATE=false` does **not** fix this; that flag governs a different step. Both clusters'
`ClientTrafficPolicy` are identical — Frostlink only works because Cloudflare supplies a public IP.

Verified working when a public IP is present, so the policy itself is correct: with
`X-Forwarded-For: 203.0.113.9` set by hand, git transport, `/api/`, `/v2/` and Gatus all reach
Forgejo and only browser HTML gets the interstitial.

Options, none yet chosen:

| Option                    | Effect                                                                     | Cost                                                                                                       |
| ------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `USE_REMOTE_ADDRESS=true` | Anubis uses the TCP peer address                                           | Every client appears as the Envoy pod IP — IP-based rules, DNSBL and per-client metrics become meaningless |
| `CUSTOM_REAL_IP_HEADER`   | Point Anubis at another header Envoy sets                                  | Needs a header carrying the true client IP; `x-envoy-external-address` is the candidate                    |
| `EnvoyPatchPolicy`        | Have Envoy set `x-real-ip` from `%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%` | Correct and general, but an xDS-level patch on shared gateway config                                       |
| External-only             | Drop `internal-gateway` from the Forgejo route                             | Loses internal access to the forge                                                                         |

Do not flip the route until one is implemented and tested.

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
