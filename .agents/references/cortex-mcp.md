# Cortex MCP Fleet — per-server reference

This file holds everything that the `cortex` MCP manifests used to say in comments. Manifests under `clusters/artemis/kubernetes/apps/cortex/` carry no prose (`yaml-conventions.md`
§ No Comments in Manifests). The reasoning lives here.

agentgateway replaced LiteLLM on 2026-10-26. The gateway also serves model traffic. This
file covers only the MCP half.

## Layout

| Piece                | Where                                                                                    |
| -------------------- | ---------------------------------------------------------------------------------------- |
| Controller + CRDs    | `clusters/artemis/kubernetes/apps/agentgateway-system/agentgateway/{crds,app}`           |
| Gateway, models, MCP | `clusters/artemis/kubernetes/apps/cortex/agentgateway/{gateway,models,mcp}`              |
| MCP server workloads | `clusters/artemis/kubernetes/apps/cortex/mcp/app/<member>` (Kustomization `mcp-servers`) |

The controller lives in its own `agentgateway-system` namespace because it is a cluster-wide
operator (`cluster-conventions.md` § App Directory Structure). The gateway and the workloads are
in `cortex`. `ls clusters/artemis/kubernetes/apps/cortex/mcp/app/` lists the fleet. The shape is the "fleet" in
`app-structure.md`. HelmRelease and Service names are `mcp-<name>` (except `victoria-logs-mcp`).

## The shape of the thing

`mcp/agentgatewaybackend.yaml` holds three `AgentgatewayBackend` objects: `mcp-ops`, `mcp-general`,
and `mcp-agent`. Each one is a list of `targets` that point at a Service. One `HTTPRoute`
(`agentgateway-mcp`) maps a path to each backend: `/ops/mcp`, `/general/mcp`, `/agent/mcp`.
`grep -n 'name:' clusters/artemis/kubernetes/apps/cortex/agentgateway/mcp/agentgatewaybackend.yaml` lists the
targets per tier.

The `agent` tier is for hermes only. It is deliberately absent from every client registration file
(`memory-config.md`). It exists because the cluster charges tool schemas on every turn of every run.
When hermes mounted `ops` and `general`, it resent about 61,500 tokens per turn. That was the largest reason it
overran the OpenCode Go monthly allowance. The `agent` tier carries only what its skills call
(`.agents/references/hermes.md` § Cost has the accounting). If you add a target to `mcp-agent`, hermes pays
for that schema on every turn.

A route-level `AgentgatewayPolicy` guards each route. The `apiKey.user_id` must equal the
identity of the tier (`ops`, `general`, `hermes`), and there must be no `Authorization` header.
The gateway-wide policy `agentgateway-auth` (Strict) does the key check. The per-route policy
decides which key can reach which tier.

### Clients must send the key as `x-api-key`

agentgateway forwards client headers on to the MCP server. So each backend strips
`x-api-key` before it forwards. It cannot do the same for `Authorization`. If it stripped that header,
it would also strip the per-target upstream tokens (forgejo, github, context7, and sparkyfitness get theirs
through `policies.auth.secretRef`). So the route
policy refuses `Authorization` outright instead. The gateway refuses a client that sends `Authorization: Bearer <key>` to an MCP path.

The models route has the matching rule. The gateway reads the key through a CEL expression, which
strips nothing. So the `agentgateway-models` policy removes `x-api-key` before the request goes
upstream. Without that policy, an `x-api-key` client that uses an OpenAI-format model would hand its gateway key
to opencode.ai (Anthropic-format models overwrite the header themselves).

### Tool names

Tools are `<target>_<tool>`, with `prefixMode: Always`. Claude Code renders them as
`mcp__ai-<tier>__<target>_<tool>` (for example `mcp__ai-general__victoria-logs_query`). The gateway fixes the `_`
separator, so target names must contain no `_` (hence `victoria-logs`,
not the old `victoria_logs`).

Target names are a frozen public interface. If you rename one, you silently break every skill, runbook
and habit that names a tool. Do not rename a target for tidiness. The old LiteLLM form was
`mcp__litellm-<tier>__<alias>-<tool>`. Anything that still uses it is stale.

### Upstream sessions: `sessionRouting: Stateless`

Every backend sets `spec.mcp.sessionRouting: Stateless`. The gateway then opens a fresh session
on each target per request and sends `DELETE` when the response is done (v1.6.0
`serve_stateless`). Under the default `Stateful`, the 30-minute idle reaper of the gateway only drops
its own entry and sends nothing upstream. So every stateful server kept every session it ever
received. `mcp-forgejo` grew about 85 MiB an hour after the 2026-10-26 swap. The CRD has no session
TTL field. The cost is one extra upstream round trip per call. Client `GET`/`DELETE`
get `405`, which the MCP spec allows.

### One replica, on purpose

`agentgatewayparameters.yaml` pins one replica. MCP sessions are stateful and live in the memory of the proxy.
A second replica would route a follow-up request from a client to a pod that has never seen
its session. Do not scale it and do not add an HPA.

### The forgejo allow-list

forgejo registers 297 tools (0.3.1, with `FORGEJO_DISABLED_AREAS` off for actions, organizations,
packages and repo-settings). The `policies.mcp.authorization` Deny rule of the backend in
`agentgatewaybackend.yaml` allows 37 of them. The 37 keep the issue-tracker, Renovate PR-triage and
code-read surface. The rule drops all `admin_*` tools, org/team/user management, notifications, templates,
social endpoints, and the file create/update/delete calls. Those calls would produce commits signed by
the instance key, which bypasses the two-identity signing model in `commit-style.md`.

The rule enforces at call time. An already-connected client keeps its cached tool list until
it reconnects, so a running session lags the config. To judge the filter, call a blocked tool
and read the error. Do not go by what the session still lists. A hand-rolled `initialize` +
`tools/list` probe is also unreliable. Use a real MCP client.

## Adding an MCP server

1. If it needs a workload, add a member under `clusters/artemis/kubernetes/apps/cortex/mcp/app/<name>/`
   (copy a sibling and list it in `mcp/app/kustomization.yaml`). Name the Service `mcp-<name>`.
2. Add a `targets` entry to the right backend or backends in `mcp/agentgatewaybackend.yaml`. The target
   `name` becomes the public tool prefix, so choose it once and without `_`.
3. If it needs an upstream token, add `policies.auth.secretRef` on the target and an ExternalSecret in
   `agentgateway/mcp/externalsecret.yaml`. Never rely on the client to send it.
4. A new tier needs more: a `backendRefs` rule in `httproute.yaml`, a route-level policy in
   `agentgatewaypolicy.yaml`, an API key (1Password item `agentgateway`, which `gateway/externalsecret.yaml`
   turns into a labelled Secret), and an entry in every registration file in `memory-config.md`.
5. Test with a real client and count the tools. The backends are `failureMode: FailOpen`, so the gateway skips a
   target that is down without a message, and the tier still answers with fewer tools.

Clients reach the tier at `https://ai.dcunha.io/<tier>/mcp` from the workstation and
`http://agentgateway.cortex.svc.cluster.local:4000/<tier>/mcp` in the cluster.

## Per-server notes

### arr (`mcp-arr`, target `arr`, general)

<https://github.com/aplaceforallmystuff/mcp-arr>. It runs the official GHCR image, not npx. The npm
publishing there is a manual step that lags far behind the tag-triggered GHCR pipeline. Versions 1.6.1 (added
`MCP_TRANSPORT=http`) through 1.7.2 (fixed a gateway/proxy deadlock in that same transport) were
never published to npm at all.

It has 48 tools. The seven `trash_*` TRaSH-guide helpers have no upstream off switch, so the
`mcp-general` backend denies them (41 left). Health is `GET /health`.

The team checked a one-server replacement for arr and Seerr on 2026-10-26. `bardesss/arr-mcp` is the only
credible one, and it needs its own config volume and UI. The team kept two servers.

### context7 (target `context7`, general)

It is a hosted endpoint at <https://mcp.context7.com/mcp>. It has no container, no workload, and nothing to harden.
The gateway sends the key as the upstream token of the target, with an explicit TLS `sni`. It has 2 tools.

### forgejo (`mcp-forgejo`, target `forgejo`, ops)

<https://code.squarecows.com/SquareCows/forgejo-mcp>, package `@ric_/forgejo-mcp`. The image is
ours, `git.dcunha.io/exikle/forgejo-mcp`. `Exikle/containers` (`apps/forgejo-mcp`) builds it from
the npm release, and it runs upstream `dist/http.js`. Renovate bumps the npm version there.

Up to 0.2.0, the HTTP bin had one process-global transport, so a single `DELETE` killed it for
good. Version 0.2.1 fixed that with a transport per session, LRU-capped at 32. Our old `http-fixed.mjs`
wrapper predated the fix, had no cap, and leaked. The team deleted it on 2026-10-26.

We override two upstream defaults: `PORT` (it defaults to 3000) and `RATE_LIMIT_MAX`. The
limit is 100 requests a minute per client IP. Every request arrives from the one IP of the gateway, and
each tool call makes four requests under stateless routing. Health is `GET /health`.

### flux (`mcp-flux`, target `flux`, ops and agent)

<https://github.com/controlplaneio-fluxcd/flux-operator>. It comes from the same vendor as the Flux Operator that this
cluster already runs. Keep the versions in step (`grep -n 'repository\|tag' clusters/artemis/kubernetes/apps/cortex/mcp/app/flux/helmrelease.yaml`
against the image of the `flux-operator` Deployment).

It runs `serve --transport http --port 8080 --read-only --mask-secrets`. `--mask-secrets` defaults
to true. We pass it explicitly so the intent survives a change of the upstream default.

`--read-only` leaves 10 tools, not the 15 that upstream documents (live tool list, 2026-10-26):
`get_flux_instance`, `get_kubernetes_api_versions`, `get_kubernetes_events`,
`get_kubernetes_logs`, `get_kubernetes_metrics`, `get_kubernetes_resources`, `read_flux_doc`,
`search_flux_docs`, `trace_kubernetes_resource`, `diff_kubernetes_manifest`. The flag disables the five mutating tools
(`reconcile_flux_resource`, `suspend_flux_reconciliation`, `resume_flux_reconciliation`,
`apply_kubernetes_manifest`, `delete_kubernetes_resource`). That is the point, because
`AGENTS.md` rule 2 forbids exactly those through MCP. `diff_kubernetes_manifest` survives
read-only. It reads and compares. It does not apply.

It uses its own ServiceAccount `mcp-flux-sa` (`flux/rbac.yaml`), bound to the existing `mcp-k8s`
ClusterRole. It does not use the default ResourceSet of the chart, which grants `cluster-admin`. The image
is distroless and runs as uid 65532, not 1000. For that reason its `podSecurityContext` differs from the rest
of the fleet.

It overlaps `k8s` on generic resource reads. The team accepted that, because `search_flux_docs` and
`get_flux_instance` are capabilities that nothing else provides. It has no health
route, so its probes are TCP.

### github (`mcp-github`, target `github`, ops)

<https://github.com/github/github-mcp-server>, official. The `http` subcommand serves Streamable
HTTP at the server root (`/`), not `/mcp`. Hence `path: ""`. The team confirmed this against
`docs/streamable-http.md` and the hosted `api.githubcopilot.com/mcp/` convention.

`GITHUB_READ_ONLY=true` is set. This repo mirrors to GitHub, and an agent never writes there.

In `http` mode, the token comes only from the `Authorization` header of the request, which the gateway
injects. Only `stdio` reads `GITHUB_PERSONAL_ACCESS_TOKEN`. So the pod mounts no token. The
ExternalSecret stays, because the `secretRef` of the gateway reads `github-mcp`. It has no health
route. The probes use the static `/.well-known/oauth-protected-resource`, because `/` returns 401.

### grafana (`mcp-grafana`, target `grafana`, general)

<https://github.com/grafana/mcp-grafana>, official. The default transport is stdio, so it needs an explicit
`-t streamable-http`.

`-allowed-hosts` is required, and it must include the service FQDN without a port. It defaults to
_loopback variants of `--address`_. agentgateway sends the target host without a port as the
`Host` header, so `mcp-grafana.cortex.svc.cluster.local` must be in the list. Without it, the server rejects every
request with `403 Forbidden` before the request reaches the MCP handler. Meanwhile the pod stays `1/1`
Running and the backend reports healthy. The same check guards `/healthz`, and the kubelet sends
the pod IP as `Host`, so the probes carry `Host: mcp-grafana:8000`.

We set `-disable-write` plus `-disable-*` for Asserts, Incident, OnCall and Pyroscope. These are the only groups
in the default `-enabled-tools` list that this cluster does not run. Athena, ClickHouse,
CloudWatch, Elasticsearch, Graphite, InfluxDB, Quickwit, Snowflake, Assistant and Agent o11y are
off by default, so their flags did nothing and the team removed them.

You mint its `GRAFANA_SERVICE_ACCOUNT_TOKEN` in Grafana under **Administration → Service
Accounts → Add service account token**.

### ha (`mcp-ha`, target `ha`, ops)

<https://github.com/homeassistant-ai/ha-mcp>. The default image CMD speaks stdio only.
`ha-mcp-web` is the dedicated HTTP entrypoint of the project (`fastmcp-http.json`: transport http,
`0.0.0.0:8086`, path `/mcp`).

It has 78 tools, and upstream ships the fix. `ENABLE_TOOL_SEARCH=true` replaces the full catalog
with about four proxy tools. The `.env.example` of upstream documents it as _"Reduces idle context
from ~46K to ~5K tokens."_ It is set. This was the single largest context win available in
the fleet.

Cold start: the first request after a restart is slow. ha-mcp builds its tool-search index
on first use. Before every target got `policies.http.requestTimeout: 300s`, the hidden
10 s default of agentgateway for MCP upstream calls cut that first request off. With `FailClosed`, that took the
whole ops tier down for a minute or two. The team fixed both. If a tier shows a 500 with
`upstream call timeout` at exactly 10 s, a target is missing its `requestTimeout`.

Upstream does publish semver image tags (`release-publish.yml`), so the pin is `<version>@sha256`
and Renovate tracks it.

`ha-mcp-web` serves an unauthenticated settings page at `/mcp/settings`.
`HA_MCP_DISABLE_SETTINGS_UI=true` turns it off. `/healthz` exists only with `MCP_HEALTHZ=true`.

You mint its `HA_TOKEN` in Home Assistant under **Profile → Long-Lived Access Tokens → Create
Token**.

### k8s (`mcp-k8s`, target `k8s`, ops and agent)

<https://github.com/containers/kubernetes-mcp-server>. Auth is the in-cluster ServiceAccount
`mcp-k8s-sa`, which the server detects automatically at runtime. `--port` starts Streamable HTTP at `/mcp` and SSE at
`/sse` at the same time. Together with `flux`, it is one of two members with `automountServiceAccountToken:
true`. They are the only ones that need an API-server identity.

The RBAC holds no `secrets` rule. In the Kubernetes API, `list` returns full objects including
`.data`. So a `secrets: list` grant would give unrestricted read of every credential, reachable
from an LLM tool endpoint. There is also no `patch` on `helmreleases`, `kustomizations` or
workloads (`AGENTS.md` rule 2: no cluster changes through MCP). The live rule set is
`kubectl get clusterrole mcp-k8s -o yaml`. `hermes.md` § RBAC summarises it.

We keep these writes on purpose, as operational actions rather than config changes: `pods/exec: create`,
`pods: delete`, `jobs: delete`, `events: create` and `*/scale`. Read-only
`fluxcd.controlplane.io` lets the ops tier look into its own control plane.

`disable_destructive = true` (in `resources/config.toml`) mechanically enforces the "never apply
cluster changes through MCP" rule. It also drops `pods_exec` and `resources_scale`, which
carry `destructiveHint=true`, so the exec and scale grants above are unused today. To get them
back, swap `disable_destructive` for an explicit `disabled_tools` list.
`disabled_tools` also removes four tools that cannot work here: `pods_run` (no `pods: create`),
`nodes_log` and `nodes_stats_summary` (no `nodes/proxy`), and `projects_list` (OpenShift).
`denied_resources` blocks Secret as a second wall behind RBAC. It has 10 tools. Health is `GET /healthz`.

### searxng (`mcp-searxng`, target `searxng`, general and agent)

<https://github.com/ihor-sokoliuk/mcp-searxng>. `MCP_HTTP_HOST` must be `0.0.0.0`. It defaults
to 127.0.0.1 only, which the gateway pod cannot reach. It has 4 tools. The in-cluster
`searxng` app backs it, not a public instance. Health is `GET /health`.

### seerr (`mcp-seerr`, target `seerr`, general)

<https://git.dcunha.io/Exikle/seerr-mcp>, a Go rewrite of upstream overseerr-mcp v2.3.1 on the
official go-sdk. The image is ours, `git.dcunha.io/exikle/seerr-mcp`. It speaks MCP 2026-07-28
plus the legacy protocol versions, and it is stateless over HTTP (no sessions).

`ALLOWED_ORIGINS` is `*`. The gateway forwards the `Origin` header of the client, and its CORS
SecurityPolicy is the origin check there.

The env var is `SEERR_URL`, not `SEERR_HOST`. If you set the wrong one, it breaks without a message.

It has 8 tools: the 6 ported ones, plus `seerr_find_api` (areas, browse, search and details over all of
the Seerr v3.5.1 API) and `seerr_call` (runs any operation). `seerr_call` masks secrets in replies
and swaps them back only into the same key in the same settings area on a write. It refuses the
key-rotating `POST /settings/main/regenerate`, `POST /settings/initialize` and `/auth/*`. Health
is `GET /health`. The app and its tools are `seerr`, not "Jellyseerr". See `media-stack.md`.

### sparkyfitness (target `sparkyfitness`, general)

It has no workload. SparkyFitness serves MCP in-process at `POST /mcp` on its server Service, so the
target points at `sparkyfitness-server.default.svc.cluster.local:3010`.

Auth is a per-user API key. You mint it in the app under **Settings → Developer & Integrations → API
Key Management** (`/settings?section=api-settings`). It is stored as `MCP_API_KEY` on the
`sparkyfitness` 1Password item. Postgres RLS scopes every tool to the user of that key.
`API_ENCRYPTION_KEY` on the same item is the at-rest encryption key of the server, not a bearer
token. It returns 401.

### victoria-logs (`victoria-logs-mcp`, target `victoria-logs`, general and agent)

<https://github.com/VictoriaMetrics/mcp-victorialogs>, official. It has 13 tools.

The workload is `victoria-logs-mcp`, while every sibling is `mcp-<x>`. The team left it alone on purpose,
because a rename costs a Deployment/Service recreate. Do not "tidy" it.

The embedded bleve index is an in-memory keyword index over its docs, not a vector DB. It sits
at 76–113 MiB of the 256Mi limit. Health is `/health/liveness` and `/health/readiness`.

## Fleet-wide

### The CORS SecurityPolicy is load-bearing

`gateway/securitypolicy.yaml` exists for browser-based MCP clients (VS Code, web UIs), not for
convenience. It must keep exposing `Mcp-Session-Id`. A client uses that header to track a stateful
streamable-http session. If you drop it, you break only those clients, without a message, while every
server-side caller keeps working.

### Security posture

Every containerised member runs `runAsNonRoot` uid/gid 1000, `allowPrivilegeEscalation: false`,
`capabilities: drop: [ALL]`, `readOnlyRootFilesystem: true` with a `/tmp` emptyDir, and
`automountServiceAccountToken: false` (except `k8s` and `flux`).

Every member has liveness, readiness and startup probes (startup: 5 s period, 30 tries). The
paths are in the section of each server above.

### Tool-surface budget

Every tool schema costs tokens on every turn, which is why the team tracks tool counts at all. The
per-server counts above are the numbers worth knowing. To measure a tier, run this from a pod with its key.
Use `x-api-key` (not `Authorization`):

```bash
curl -s -X POST "http://agentgateway.cortex.svc.cluster.local:4000/<tier>/mcp" \
  -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

That proves the handshake. A full `tools/list` needs the `Mcp-Session-Id` that the `initialize` reply
returns. Use a real MCP client when you need the byte count.
