# Cortex MCP Fleet — per-server reference

Everything the `cortex` MCP manifests used to say in comments, plus what the 2026-08-29 audit
established. Manifests under `kubernetes/apps/cortex/` carry no prose (`yaml-conventions.md`
§ No Comments in Manifests); this file is where the reasoning lives.

Layout: `kubernetes/apps/cortex/litellm/{operator,proxy,mcp/<member>}`. One Flux Kustomization
(`litellm-mcp-servers`) owns all ten members. See
`.agents/instructions/cluster-conventions.md` § App Directory Structure.

## The shape of the thing

`litellm-operator` reconciles a single `LiteLLMProxy` that aggregates every `LiteLLMMCPServer`.
Tier separation is **inside** the proxy — each server's `spec.params.access_groups` plus
URL namespacing (`/general/mcp`, `/media/mcp`, `/ops/mcp`) — not separate proxy processes or
Services. bjw-s-labs/home-ops, the only working reference deployment, does the same. The prior
three-tier ToolHive split was never NetworkPolicy-enforced either; it was client-side config
hygiene, so one proxy does not weaken anything.

**Tool names clients see are `mcp__litellm-<tier>__<alias>-<tool>`.** `spec.alias` is therefore
a frozen public interface — renaming one silently breaks every skill, runbook and habit that
names a tool. Do not rename an alias for tidiness.

### The HTTPRoute must not be named `litellm`

`litellm/proxy/httproute.yaml` is named **`litellm-mcp`**, deliberately. `litellm-operator`
claims the HTTPRoute named after its `LiteLLMProxy`: `spec.route` "makes the operator create and
own a Gateway API HTTPRoute that fronts the proxy Service", and with `spec.route` **unset** the
operator _deletes_ that route to converge. It was silently removing our route about a minute
after every Flux apply. Flux stayed green — the delete happened out-of-band _after_ a successful
apply — and only re-created it on the 1h interval. Every path on `litellm.dcunha.io` 404'd in
between.

Moving the route into `LiteLLMProxy.spec.route` is the obvious alternative and does not work:
that schema carries only `hostnames`/`parentRefs`/`filters`. It cannot express
`timeouts.request: 0s` (needed so Envoy does not cut long completions) or the gatus annotation.
Revisit if the operator's route schema grows them.

### Postgres: no pgbouncer, and Prisma needs its own DSN key

`litellm/ks.yaml` pulls in `components/postgres/app`. litellm ran a standalone `litellm-pgbouncer`
Deployment until 2026-09-01, purely because Prisma cannot present a PEM **client** cert. Password
auth removed that reason and the sidecar is gone, along with its ini, userlist, configMapGenerator
and NetworkPolicy.

Prisma still needs its own DSN dialect, which is why the component emits three. Prisma's PostgreSQL
connector accepts `sslcert` (meaning the **root** cert) and `sslidentity` (a PKCS#12 bundle); it has
**no `sslkey` and no `sslrootcert`**, and silently drops unknown connection-string params
(`Discarding connection string param`, verified in the query-engine binary). So litellm uses the
`url_prisma` key. Handing it the plain `url` would leave it on `verify-full` with the CA param
dropped — a failure that connects _without_ verifying rather than erroring.

Two things specific to this app:

- **The CR mounts the server CA itself.** `components/postgres/app/patch` targets `HelmRelease`
  only, and `LiteLLMProxy` is a CR, so `spec.volumes`/`spec.volumeMounts` are declared on
  `litellmproxy.yaml`. Under the old component litellm carried `skip-cert-patch` and had no CA
  mounted at all — it relied entirely on the sidecar. Its annotation is now
  `postgres.dcunha.io/skip-patch`.
- **No scheduling gates.** `LiteLLMProxy` has no `schedulingGates` field, so the ksgate ordering is
  HelmRelease-only. That is startup ordering, not correctness — the proxy retries until Postgres is
  up. Prisma runs its migrations on boot (157 of them at last count), so a slow first start is
  normal.

## Per-server notes

### arr (`mcp-arr`, alias `arr`, media)

<https://github.com/aplaceforallmystuff/mcp-arr>. Runs the official GHCR image, **not npx**: npm
publishing there is a manual step that lags the tag-triggered GHCR pipeline badly. 1.6.1 (added
`MCP_TRANSPORT=http`) through 1.7.2 (fixed a gateway/proxy deadlock in that same transport —
exactly the failure mode litellm's gateway would hit) were never published to npm at all.

48 tools, a large share of them TRaSH-guide helpers. Worth revisiting whether those earn their
schema cost.

### context7 (`mcp-context7`, alias `context7`, general)

Hosted endpoint at <https://mcp.context7.com/mcp> — no container, no workload, nothing to harden.
2 tools.

### forgejo (`mcp-forgejo`, alias `forgejo`, ops) — the patched one

<https://code.squarecows.com/SquareCows/forgejo-mcp>. Package `@ric_/forgejo-mcp@0.1.7` declares
two bins in one package: `forgejo-mcp` (stdio, `dist/index.js`) and `forgejo-mcp-http`
(`dist/http.js`). There is no separate `@ric_/forgejo-mcp-http` package — a since-fixed README
error pointed there; it 404s on the npm registry. Endpoint is `/mcp`.

**The upstream HTTP bin is unusable behind LiteLLM.** `dist/http.js` builds ONE process-global
stateful `StreamableHTTPServerTransport` at startup, so the process serves exactly one MCP
session for its lifetime, and a client's `DELETE /mcp` closes that transport permanently. Every
later request returns `404 -32001 "Session not found"` while `/health` keeps answering 200 — so
nothing restarts the pod and the failure is invisible to probes. LiteLLM opens and terminates a
session per call, so it bricks the server on first use. Broken in every published version through
0.1.7.

We install the package at boot and run `resources/http-fixed.mjs` (mounted from the
`forgejo-mcp-configmap` ConfigMap), which keeps a transport per session. The file is copied out
of the read-only mount into `/tmp/app` so Node's ESM resolver finds `/tmp/app/node_modules` —
`NODE_PATH` does not apply to ESM imports.

**npm latest is still 0.1.7**, the broken version, from a 14-commit project. A bump past 0.1.7
would silently break the patch's imports, so the version is pinned in the `command` string and
wants a Renovate guard.

**103 tools — the largest toolset in the fleet**, corroborated by upstream's own description.
Reducing it means filtering inside `http-fixed.mjs`, unless the operator gains an allow-list.

### flux (`mcp-flux`, alias `flux`, ops)

<https://github.com/controlplaneio-fluxcd/flux-operator>, same vendor and same version as the
Flux Operator this cluster already runs (v0.58.1 — keep them in step). Added 2026-08-29.

Runs `serve --transport http --port 8080 --read-only --mask-secrets`. `--mask-secrets` defaults
true; it is passed explicitly so the intent survives an upstream default change.

**`--read-only` leaves 6 tools, not the 15 upstream documents** — verified live, not assumed:
`get_flux_instance`, `get_kubernetes_api_versions`, `get_kubernetes_logs`,
`get_kubernetes_metrics`, `get_kubernetes_resources`, `search_flux_docs`. The mutating five
(`reconcile_flux_resource`, `suspend_flux_reconciliation`, `resume_flux_reconciliation`,
`apply_kubernetes_manifest`, `delete_kubernetes_resource`) are disabled, which is the point —
`tooling.md` § Critical Rules forbids exactly those through MCP. Note that
`diff_kubernetes_manifest` is **also** gone in read-only mode, contrary to what its docs imply;
do not plan the `flux-validate` skill around it.

Uses its own ServiceAccount `mcp-flux-sa` bound to the existing `mcp-k8s` ClusterRole rather than
the chart's default ResourceSet, which grants `cluster-admin`. The image is distroless and runs
as uid **65532**, not 1000 — its `podSecurityContext` differs from the rest of the fleet for that
reason.

Overlaps `k8s-mcp` on generic resource reads. That is accepted for now; the ops tier gained only
6 schemas and `search_flux_docs` plus `get_flux_instance` are capabilities nothing else provides.

### github (`mcp-github`, alias `github`, ops)

<https://github.com/github/github-mcp-server>, official. The `http` subcommand serves Streamable
HTTP at the server **root** (`/`), not `/mcp` — hence `path: ""`. Confirmed against
`docs/streamable-http.md` and the hosted `api.githubcopilot.com/mcp/` convention.

`GITHUB_READ_ONLY=true` is set: this repo mirrors to GitHub and never writes there from an agent.
44 tools on upstream defaults.

### grafana (`mcp-grafana`, alias `grafana`, general)

<https://github.com/grafana/mcp-grafana>, official. Default transport is stdio — needs explicit
`-t streamable-http`.

**Why it served zero tools, and the fix.** `-allowed-hosts` defaults to _loopback variants of
`--address`_. We pass `-address 0.0.0.0:8000` and LiteLLM dials the service FQDN, so every
request was rejected with `403 Forbidden` before reaching the MCP handler. Proven from the
litellm pod: `Host: mcp-grafana.cortex.svc.cluster.local:8000` → 403,
`Host: localhost:8000` → 200. The pod had been logging the rejection the whole time and nobody
was reading it.

Fixed by passing `-allowed-hosts` with all four in-cluster name forms. Because that restores
roughly 60 tools at once, it lands together with `-disable-write` and with `-disable-*` for the
products this cluster does not run (Athena, ClickHouse, CloudWatch, Elasticsearch, Graphite,
InfluxDB, Quickwit, Snowflake, Pyroscope, OnCall, Incident, Sift, Asserts, Assistant,
Agent o11y). Re-enable a group only when the matching datasource actually exists.

### ha (`mcp-ha`, alias `ha`, ops)

<https://github.com/homeassistant-ai/ha-mcp>. The default image CMD speaks stdio only;
`ha-mcp-web` is the project's dedicated HTTP entrypoint (`fastmcp-http.json`: transport http,
`0.0.0.0:8086`, path `/mcp`) — confirmed against bjw-s-labs/home-ops's adoption of the same
server.

**78 tools, and upstream ships the fix.** `ENABLE_TOOL_SEARCH=true` replaces the full catalog
with about four proxy tools; upstream's `.env.example` documents it as _"Reduces idle context
from ~46K to ~5K tokens."_ It is now set. This was the single largest context win available in
the fleet.

**Image pinning is unmanageable.** Upstream publishes only `latest` and `dev-<sha>` tags — no
semver — so `latest@sha256:…` is the best available pin and Renovate cannot track it. Bump by
re-resolving the digest by hand.

### k8s (`mcp-k8s`, alias `k8s`, ops)

<https://github.com/containers/kubernetes-mcp-server>. Auth is the in-cluster ServiceAccount
`mcp-k8s-sa`, auto-detected at runtime. `--port` starts Streamable HTTP at `/mcp` and SSE at
`/sse` simultaneously. This is the only member with `automountServiceAccountToken: true`; it is
the only one that needs an API-server identity.

**RBAC was far too wide (fixed 2026-08-29).** The ClusterRole granted `secrets: list`
cluster-wide. In the Kubernetes API `list` returns full objects **including `.data`**, so that
was unrestricted read of every credential in the cluster, reachable from an LLM tool endpoint —
and the manifest's own stated intent never mentioned secrets. Removed. Also removed: `patch` on
`helmreleases` and `kustomizations` (which RBAC-permitted precisely what `tooling.md`
§ Critical Rules forbids), and `patch`/`update` on workloads.

Kept deliberately: `pods/exec: create`, `pods: delete`, and `*/scale` — `cluster-conventions.md`
§ Cluster Inspection explicitly blesses exec and scale as MCP operations.

Added: read-only `fluxcd.controlplane.io` and `litellm.home-operations.com` so the ops tier can
introspect its own control plane. The audit hit that gap directly.

`--disable-destructive` is set, which mechanically enforces the "never apply cluster changes
through MCP" rule instead of relying on convention. **Do not use `--read-only`** — it drops
`exec` and `scale`, which are blessed above. 20 tools.

### searxng (`mcp-searxng`, alias `searxng`, general)

<https://github.com/ihor-sokoliuk/mcp-searxng>. `MCP_HTTP_HOST` must be `0.0.0.0` — it defaults
to 127.0.0.1-only, which is unreachable from the litellm proxy pod. 4 tools. Backed by the
in-cluster `searxng` app, not a public instance.

### seerr (`mcp-seerr`, alias `seerr`, media)

<https://www.npmjs.com/package/@jhomen368/overseerr-mcp>. Pinned (was unpinned under ToolHive)
because litellm-operator has no proxy layer to absorb an upstream regression.

**The env var is `SEERR_URL`, not `SEERR_HOST`.** Setting the wrong one breaks it silently.

6 tools. The app and its tools are `seerr`, not "Jellyseerr" — see `media-stack.md`.

### victoria-logs (`victoria-logs-mcp`, alias `victoria_logs`, general)

<https://github.com/VictoriaMetrics/mcp-victorialogs>, official. 13 tools.

Two naming inconsistencies, both deliberately **not** fixed: the CR is `victoria-logs-mcp` while
every sibling is `mcp-<x>`, and the alias uses an underscore (`victoria_logs`) while every
sibling uses none. Renaming either costs a Deployment/Service recreate, and the alias is a
client-visible tool name (see above). Left alone on purpose; do not "tidy" it.

Upstream has been dormant since 2026-04-20. The embedded bleve vector DB against a 256Mi limit
is a suspected OOM risk — **unverified**, no OOMKills observed. Check restart counts before
acting on it.

### Trimming a server's toolset — `allowed_tools`

`LiteLLMMCPServer.spec.params` is free-form passthrough into LiteLLM's `mcp_servers` config
entry, and LiteLLM v1.98.0's `MCPServer` model supports **`allowed_tools`** and
**`disallowed_tools`** (read at `mcp_server_manager.py:1741`). So a bloated server is trimmed
with config alone — no forked image, no proxy layer.

`forgejo` uses it: 103 tools down to **37**, keeping the issue-tracker, Renovate PR-triage and
code-read surface and dropping all `admin_*`, org/team/user management, notifications, templates,
social endpoints, and the file create/update/delete calls (those would produce commits signed by
the instance key, bypassing the two-identity signing model in `commit-style.md`).

Two things to know about how it enforces:

- **It gates at call time**, returning `Tool <name> is not allowed for server <alias>`. Verified
  live: `admin_list_cron_jobs` is refused, `list_labels` still works.
- **An already-connected client keeps its cached schema list** until it reconnects, so the
  advertised tool count in a running session lags the config. Do not judge the filter by what a
  live session still lists — call a blocked tool and read the error.

`arr` (48 tools, many of them TRaSH-guide helpers) is a candidate for the same treatment but was
deliberately left alone — deciding which TRaSH tools earn their keep is a media-stack judgement,
not a cleanup.

**Verifying tool counts is harder than it looks.** A hand-rolled `initialize` + `tools/list`
against `/<tier>/mcp` returns an empty list even with a valid key, and `/mcp-rest/tools/list`
answers `The key is not allowed to access any MCP servers` — neither reflects what a real client
sees. Use an actual MCP client, or call a tool and read the result.

## Fleet-wide

### Security posture

Every containerised member runs `runAsNonRoot` uid/gid 1000, `allowPrivilegeEscalation: false`,
`capabilities: drop: [ALL]`, `readOnlyRootFilesystem: true` with a `/tmp` emptyDir, and
`automountServiceAccountToken: false` (except `k8s`). The CRD supports all of these under
`spec.workload` — verified with `kubectl explain litellmmcpserver.spec.workload`.

**`LiteLLMProxy.spec` has no equivalent fields**, so the proxy itself still runs unhardened as
the `default` ServiceAccount. That needs an upstream change; it is not fixable here.

### Tool-surface budget

Every tool schema costs tokens on every turn, which is why this is tracked at all. Census taken
2026-08-29 from the live tool listing, before the fixes above:

| Tier    | Server        |      Tools |
| ------- | ------------- | ---------: |
| ops     | forgejo       |        103 |
| ops     | ha            |         78 |
| ops     | github        |         44 |
| ops     | k8s           |         20 |
| media   | arr           |         48 |
| media   | seerr         |          6 |
| general | victoria_logs |         13 |
| general | searxng       |          4 |
| general | context7      |          2 |
| general | grafana       | 0 (broken) |
|         | **total**     |    **318** |

`litellm-ops` alone carried 245 of them — 77%.
