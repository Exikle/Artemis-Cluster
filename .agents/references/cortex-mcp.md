# Cortex MCP Fleet — per-server reference

Everything the `cortex` MCP manifests used to say in comments. Manifests under `kubernetes/apps/cortex/` carry no prose (`yaml-conventions.md`
§ No Comments in Manifests); this file is where the reasoning lives.

LiteLLM was replaced by agentgateway on 2026-10-26. The gateway also serves model traffic; this
file covers only the MCP half.

## Layout

| Piece                | Where                                                                   |
| -------------------- | ----------------------------------------------------------------------- |
| Controller + CRDs    | `kubernetes/apps/agentgateway-system/agentgateway/{crds,app}`           |
| Gateway, models, MCP | `kubernetes/apps/cortex/agentgateway/{gateway,models,mcp}`              |
| MCP server workloads | `kubernetes/apps/cortex/mcp/app/<member>` (Kustomization `mcp-servers`) |

The controller lives in its own `agentgateway-system` namespace because it is a cluster-wide
operator (`cluster-conventions.md` § App Directory Structure). The gateway and the workloads are
in `cortex`. `ls kubernetes/apps/cortex/mcp/app/` lists the fleet; the shape is the "fleet" in
`app-structure.md`. HelmRelease and Service names are `mcp-<name>` (except `victoria-logs-mcp`).

## The shape of the thing

Three `AgentgatewayBackend` objects in `mcp/agentgatewaybackend.yaml` — `mcp-ops`, `mcp-general`,
`mcp-agent` — each a list of `targets` pointing at a Service. One `HTTPRoute`
(`agentgateway-mcp`) maps a path to each backend: `/ops/mcp`, `/general/mcp`, `/agent/mcp`.
`grep -n 'name:' kubernetes/apps/cortex/agentgateway/mcp/agentgatewaybackend.yaml` lists the
targets per tier.

`agent` is for hermes only and is deliberately absent from every client registration file
(`memory-config.md`). It exists because tool schemas are charged on every turn of every run:
hermes mounting `ops` + `general` resent about 61,500 tokens per turn, the largest driver of it
overrunning the OpenCode Go monthly allowance. `agent` carries only what its skills call
(`.agents/references/hermes.md` § Cost has the accounting). Adding a target to `mcp-agent` costs
hermes that schema every turn.

Each route is guarded by a route-level `AgentgatewayPolicy`: `apiKey.user_id` must equal the
tier's identity (`ops`, `general`, `hermes`) **and** there must be no `Authorization` header.
The gateway-wide policy `agentgateway-auth` (Strict) does the key check; the per-route policy
decides which key may reach which tier.

### Clients must send the key as `x-api-key`

agentgateway forwards client headers on to the MCP server. Each backend therefore strips
`x-api-key` before forwarding. It cannot do the same for `Authorization`: stripping that header
would also strip the per-target upstream tokens (forgejo, github, context7, sparkyfitness are
injected through `policies.auth.secretRef`). So `Authorization` is refused outright by the route
policy instead. A client that sends `Authorization: Bearer <key>` to an MCP path is refused.

The models route has the matching rule: the gateway reads the key through a CEL expression, which
strips nothing, so the `agentgateway-models` policy removes `x-api-key` before the request goes
upstream. Without it, an `x-api-key` client using an OpenAI-format model would hand its gateway key
to opencode.ai (Anthropic-format models overwrite the header themselves).

### Tool names

Tools are `<target>_<tool>`, with `prefixMode: Always`; Claude Code renders them
`mcp__ai-<tier>__<target>_<tool>` (for example `mcp__ai-general__victoria-logs_query`). The `_`
separator is fixed by the gateway, so target names must contain no `_` (hence `victoria-logs`,
not the old `victoria_logs`).

**Target names are a frozen public interface.** Renaming one silently breaks every skill, runbook
and habit that names a tool. Do not rename a target for tidiness. The old LiteLLM form was
`mcp__litellm-<tier>__<alias>-<tool>`; anything still using it is stale.

### One replica, on purpose

`agentgatewayparameters.yaml` pins one replica. MCP sessions are stateful and live in the proxy's
memory; a second replica would route a client's follow-up request to a pod that has never seen
its session. Do not scale it or add an HPA.

### The forgejo allow-list

forgejo exposes 103 tools; the backend `policies.mcp.authorization` Deny rule in
`agentgatewaybackend.yaml` allows 37 of them, keeping the issue-tracker, Renovate PR-triage and
code-read surface. It drops all `admin_*`, org/team/user management, notifications, templates,
social endpoints, and the file create/update/delete calls (those would produce commits signed by
the instance key, bypassing the two-identity signing model in `commit-style.md`).

The rule enforces at call time. **An already-connected client keeps its cached tool list** until
it reconnects, so a running session lags the config. Judge the filter by calling a blocked tool
and reading the error, not by what the session still lists. A hand-rolled `initialize` +
`tools/list` probe is also unreliable; use a real MCP client.

## Adding an MCP server

1. If it needs a workload, add a member under `kubernetes/apps/cortex/mcp/app/<name>/`
   (copy a sibling; list it in `mcp/app/kustomization.yaml`). Service name `mcp-<name>`.
2. Add a `targets` entry to the right backend(s) in `mcp/agentgatewaybackend.yaml`. The target
   `name` becomes the public tool prefix, so choose it once and without `_`.
3. Upstream token needed? Add `policies.auth.secretRef` on the target and an ExternalSecret in
   `agentgateway/mcp/externalsecret.yaml`. Never rely on the client to send it.
4. A new tier needs more: a `backendRefs` rule in `httproute.yaml`, a route-level policy in
   `agentgatewaypolicy.yaml`, an API key (1Password item `agentgateway`, which `gateway/externalsecret.yaml`
   turns into a labelled Secret), and every registration file in `memory-config.md`.
5. Test with a real client and count the tools: the backends are `failureMode: FailOpen`, so a
   target that is down is skipped silently and the tier still answers with fewer tools.

Clients reach the tier at `https://ai.dcunha.io/<tier>/mcp` from the workstation and
`http://agentgateway.cortex.svc.cluster.local:4000/<tier>/mcp` in-cluster.

## Per-server notes

### arr (`mcp-arr`, target `arr`, general)

<https://github.com/aplaceforallmystuff/mcp-arr>. Runs the official GHCR image, **not npx**: npm
publishing there is a manual step that lags the tag-triggered GHCR pipeline badly. 1.6.1 (added
`MCP_TRANSPORT=http`) through 1.7.2 (fixed a gateway/proxy deadlock in that same transport) were
never published to npm at all.

48 tools, a large share of them TRaSH-guide helpers. Worth revisiting whether those earn their
schema cost; trimming would be a backend authorization rule like forgejo's.

### context7 (target `context7`, general)

Hosted endpoint at <https://mcp.context7.com/mcp> — no container, no workload, nothing to harden.
The key is sent as the target's upstream token, with an explicit TLS `sni`. 2 tools.

### forgejo (`mcp-forgejo`, target `forgejo`, ops) — the patched one

<https://code.squarecows.com/SquareCows/forgejo-mcp>. Package `@ric_/forgejo-mcp` declares two
bins in one package: `forgejo-mcp` (stdio, `dist/index.js`) and `forgejo-mcp-http`
(`dist/http.js`). There is no separate `@ric_/forgejo-mcp-http` package; it 404s on npm.
Endpoint is `/mcp`.

**The upstream HTTP bin is unusable behind a gateway that opens a session per call.**
`dist/http.js` builds ONE process-global stateful `StreamableHTTPServerTransport` at startup, so
the process serves exactly one MCP session for its lifetime, and a client's `DELETE /mcp` closes
that transport permanently. Every later request returns `404 -32001 "Session not found"` while
`/health` keeps answering 200 — so nothing restarts the pod and the failure is invisible to
probes.

We install the package at boot and run `resources/http-fixed.mjs` (mounted from a generated
ConfigMap), which keeps a transport per session. The file is copied out of the read-only mount
into `/tmp/app` so Node's ESM resolver finds `/tmp/app/node_modules` — `NODE_PATH` does not apply
to ESM imports. The package version is pinned in the `command` string; a bump can silently break
the patch's imports (`grep -n forgejo-mcp kubernetes/apps/cortex/mcp/app/forgejo/helmrelease.yaml`),
and wants a Renovate guard ([#2768](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2768)).

### flux (`mcp-flux`, target `flux`, ops and agent)

<https://github.com/controlplaneio-fluxcd/flux-operator>, same vendor as the Flux Operator this
cluster already runs; keep the versions in step (`grep -n 'repository\|tag' kubernetes/apps/cortex/mcp/app/flux/helmrelease.yaml`
against the `flux-operator` Deployment image).

Runs `serve --transport http --port 8080 --read-only --mask-secrets`. `--mask-secrets` defaults
true; it is passed explicitly so the intent survives an upstream default change.

**`--read-only` leaves 7 tools, not the 15 upstream documents** — verified live, not assumed:
`get_flux_instance`, `get_kubernetes_api_versions`, `get_kubernetes_logs`,
`get_kubernetes_metrics`, `get_kubernetes_resources`, `search_flux_docs`,
`diff_kubernetes_manifest`. The mutating five
(`reconcile_flux_resource`, `suspend_flux_reconciliation`, `resume_flux_reconciliation`,
`apply_kubernetes_manifest`, `delete_kubernetes_resource`) are disabled, which is the point —
`AGENTS.md` rule 2 forbids exactly those through MCP. `diff_kubernetes_manifest` survives
read-only: it reads and compares, it does not apply.

Uses its own ServiceAccount `mcp-flux-sa` (`flux/rbac.yaml`) bound to the existing `mcp-k8s`
ClusterRole rather than the chart's default ResourceSet, which grants `cluster-admin`. The image
is distroless and runs as uid **65532**, not 1000 — its `podSecurityContext` differs from the rest
of the fleet for that reason.

Overlaps `k8s` on generic resource reads. That is accepted; `search_flux_docs` plus
`get_flux_instance` are capabilities nothing else provides.

### github (`mcp-github`, target `github`, ops)

<https://github.com/github/github-mcp-server>, official. The `http` subcommand serves Streamable
HTTP at the server **root** (`/`), not `/mcp` — hence `path: ""`. Confirmed against
`docs/streamable-http.md` and the hosted `api.githubcopilot.com/mcp/` convention.

`GITHUB_READ_ONLY=true` is set: this repo mirrors to GitHub and never writes there from an agent.
44 tools on upstream defaults.

### grafana (`mcp-grafana`, target `grafana`, general)

<https://github.com/grafana/mcp-grafana>, official. Default transport is stdio — needs explicit
`-t streamable-http`.

**`-allowed-hosts` is required, and must include the port-less service FQDN.** It defaults to
_loopback variants of `--address`_. agentgateway sends the target host **without a port** as the
`Host` header, so `mcp-grafana.cortex.svc.cluster.local` must be in the list; without it every
request is rejected `403 Forbidden` before reaching the MCP handler, while the pod stays `1/1`
Running and the backend reports healthy. It is set together with `-disable-write` and
`-disable-*` for the products this cluster does not run (Athena, ClickHouse, CloudWatch,
Elasticsearch, Graphite, InfluxDB, Quickwit, Snowflake, Pyroscope, OnCall, Incident, Sift,
Asserts, Assistant, Agent o11y). Re-enable a group only when the matching datasource exists.

Its `GRAFANA_SERVICE_ACCOUNT_TOKEN` is minted in Grafana under **Administration → Service
Accounts → Add service account token**.

### ha (`mcp-ha`, target `ha`, ops)

<https://github.com/homeassistant-ai/ha-mcp>. The default image CMD speaks stdio only;
`ha-mcp-web` is the project's dedicated HTTP entrypoint (`fastmcp-http.json`: transport http,
`0.0.0.0:8086`, path `/mcp`).

**78 tools, and upstream ships the fix.** `ENABLE_TOOL_SEARCH=true` replaces the full catalog
with about four proxy tools; upstream's `.env.example` documents it as _"Reduces idle context
from ~46K to ~5K tokens."_ It is set. This was the single largest context win available in
the fleet.

**Cold start: the first request after a restart is slow.** ha-mcp builds its tool-search index
on first use. Before every target got `policies.http.requestTimeout: 300s`, agentgateway's hidden
10 s default for MCP upstream calls cut that first request off, and with `FailClosed` it took the
whole ops tier down for a minute or two. Both are fixed; if a tier shows a 500 with
`upstream call timeout` at exactly 10 s, a target is missing its `requestTimeout`.

**Image pinning is unmanageable.** Upstream publishes only `latest` and `dev-<sha>` tags — no
semver — so `latest@sha256:…` is the best available pin and Renovate cannot track it. Bump by
re-resolving the digest by hand.

Its `HA_TOKEN` is minted in Home Assistant under **Profile → Long-Lived Access Tokens → Create
Token**.

### k8s (`mcp-k8s`, target `k8s`, ops and agent)

<https://github.com/containers/kubernetes-mcp-server>. Auth is the in-cluster ServiceAccount
`mcp-k8s-sa`, auto-detected at runtime. `--port` starts Streamable HTTP at `/mcp` and SSE at
`/sse` simultaneously. With `flux`, it is one of two members with `automountServiceAccountToken:
true`; they are the only ones that need an API-server identity.

**RBAC holds no `secrets` rule.** In the Kubernetes API `list` returns full objects **including
`.data`**, so a `secrets: list` grant would be unrestricted read of every credential, reachable
from an LLM tool endpoint. There is also no `patch` on `helmreleases`, `kustomizations` or
workloads (`AGENTS.md` rule 2: no cluster changes through MCP). The live rule set is
`kubectl get clusterrole mcp-k8s -o yaml`; `hermes.md` § RBAC summarises it.

Writes kept deliberately, as operational actions rather than config changes: `pods/exec: create`,
`pods: delete`, `jobs: delete`, `events: create` and `*/scale`. Read-only
`fluxcd.controlplane.io` lets the ops tier introspect its own control plane.

`--disable-destructive` is set, which mechanically enforces the "never apply cluster changes
through MCP" rule instead of relying on convention. **Do not use `--read-only`** — it drops
`exec` and `scale`. 20 tools.

### searxng (`mcp-searxng`, target `searxng`, general and agent)

<https://github.com/ihor-sokoliuk/mcp-searxng>. `MCP_HTTP_HOST` must be `0.0.0.0` — it defaults
to 127.0.0.1-only, which is unreachable from the gateway pod. 4 tools. Backed by the in-cluster
`searxng` app, not a public instance.

### seerr (`mcp-seerr`, target `seerr`, general)

<https://www.npmjs.com/package/@jhomen368/overseerr-mcp>. Pinned because there is no proxy layer
to absorb an upstream regression.

**The env var is `SEERR_URL`, not `SEERR_HOST`.** Setting the wrong one breaks it silently.

6 tools. The app and its tools are `seerr`, not "Jellyseerr" — see `media-stack.md`.

### sparkyfitness (target `sparkyfitness`, general)

No workload. SparkyFitness serves MCP in-process at `POST /mcp` on its server Service, so the
target points at `sparkyfitness-server.default.svc.cluster.local:3010`.

Auth is a per-user API key minted in the app under **Settings → Developer & Integrations → API
Key Management** (`/settings?section=api-settings`), stored as `MCP_API_KEY` on the
`sparkyfitness` 1Password item. Every tool is scoped to that key's user by Postgres RLS.
`API_ENCRYPTION_KEY` on the same item is the server's at-rest encryption key, not a bearer
token — it 401s.

### victoria-logs (`victoria-logs-mcp`, target `victoria-logs`, general and agent)

<https://github.com/VictoriaMetrics/mcp-victorialogs>, official. 13 tools.

The workload is `victoria-logs-mcp` while every sibling is `mcp-<x>`. Left alone on purpose:
renaming costs a Deployment/Service recreate. Do not "tidy" it.

Upstream has been dormant since 2026-04-20. The embedded bleve vector DB against a 256Mi limit
is a suspected OOM risk — **unverified**, no OOMKills observed. Check restart counts before
acting on it.

## Fleet-wide

### The CORS SecurityPolicy is load-bearing

`gateway/securitypolicy.yaml` exists for browser-based MCP clients (VS Code, web UIs), not for
convenience. It must keep exposing `Mcp-Session-Id` — that is how a client tracks a stateful
streamable-http session, and dropping it breaks those clients only, silently, while every
server-side caller keeps working.

### Security posture

Every containerised member runs `runAsNonRoot` uid/gid 1000, `allowPrivilegeEscalation: false`,
`capabilities: drop: [ALL]`, `readOnlyRootFilesystem: true` with a `/tmp` emptyDir, and
`automountServiceAccountToken: false` (except `k8s` and `flux`).

### Tool-surface budget

Every tool schema costs tokens on every turn, which is why tool counts are tracked at all. The
per-server counts above are the numbers worth knowing. Measure a tier from a pod with its key,
using `x-api-key` (not `Authorization`):

```bash
curl -s -X POST "http://agentgateway.cortex.svc.cluster.local:4000/<tier>/mcp" \
  -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

That proves the handshake. A full `tools/list` needs the `Mcp-Session-Id` the `initialize` reply
returns; use a real MCP client when you need the byte count.
