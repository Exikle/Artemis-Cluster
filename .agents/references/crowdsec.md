# CrowdSec — Blocking Bad IPs on edge-gateway

CrowdSec protects every public HTTP route on `edge-gateway`. Artemis and Frostlink are not
meshed. Public traffic reaches Artemis only through towonel on Frostlink (SNI passthrough, PROXY
v2). So the real client IP first appears at `edge-gateway`, and that is where CrowdSec sits.
Tracking issue: #2584.

Upstream: <https://docs.crowdsec.net>, bouncer <https://github.com/kdwils/envoy-proxy-bouncer>

---

## How it fits together

| Piece                 | Where                                                | Job                                                                       |
| --------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------- |
| LAPI                  | `security/crowdsec-lapi`, SQLite on a PVC            | Holds decisions; pulls the community blocklist (CAPI)                     |
| Agents                | `security/crowdsec-agent` DaemonSet                  | Read only `network/edge-gateway-*` logs, raise alerts                     |
| Bouncer               | `security/crowdsec-bouncer`, 2 replicas              | gRPC ext_authz server; answers allow/deny per request                     |
| `SecurityPolicy/edge` | `network`, in `envoy-gateway/app/envoy.yaml`         | Points `edge-gateway` at the bouncer, `failOpen: true`, 1s timeout        |
| Bouncer API key       | 1Password item `crowdsec`, field `BOUNCER_KEY_ENVOY` | LAPI registers bouncer `ENVOY` from it; the bouncer reads the same Secret |

The namespace is `security`, beside pocket-id and tinyauth. There is no dedicated `crowdsec`
namespace. The LAPI uses SQLite, not shared Postgres. The LAPI is the only writer, and the data is
rebuildable (the blocklist re-syncs, local decisions expire).

### Fail open is deliberate

If the bouncer is down or slow, Envoy lets the request through after 1s. A dead bouncer therefore
looks like nothing at all. Sites stay up, unprotected. `CrowdSecBouncerDown` exists for this
reason. Treat it as a real alert, not noise.

## Exemptions live in two places — keep them in sync

| Where                                                  | What it stops                    |
| ------------------------------------------------------ | -------------------------------- |
| `config.exemptIPs` in `bouncer/helmrelease.yaml`       | The bouncer ever blocking the IP |
| `edge-whitelist.yaml` parser in `app/helmrelease.yaml` | The agents raising alerts on it  |

Exempt today: `10.0.0.0/8` (home LAN: split DNS sends home clients straight to `10.10.99.90`)
and `40.233.88.33` (the public IP of Frostlink, because its own probes come through towonel). The LAN
range is only in the bouncer list because the agents already skip private ranges through the
`crowdsecurity/whitelists` parser.

## What is not covered

- Routes with their own extAuth. Envoy Gateway allows one extAuth per route. A route-level
  SecurityPolicy replaces the Gateway-level one unless it sets `mergeType: StrategicMerge`.
  `components/envoy-oidc` sets it, so OIDC routes get both. tinyauth routes use extAuth
  themselves, so they override CrowdSec. Find them with
  `grep -rln components/tinyauth kubernetes/apps/`. Check with
  `kubectl get securitypolicy -n network edge -o jsonpath='{.status.ancestors[*].conditions[*].message}'`.
- towonel TCP/UDP services. They bypass `edge-gateway` (see `towonel-agent.md` § Beyond
  HTTPS).
- Anything on `internal-gateway`. It is LAN only, by design.

## Bot challenge

The bot challenge replaced Anubis on `git.dcunha.io` and `jelu.dcunha.io`. A browser must solve a
proof-of-work check before it reaches the app. Plain `curl` and other clients without JavaScript
get the challenge page too, unless a rule exempts them. CrowdSec calls this feature bot detection,
and it is alpha in CrowdSec 1.8.

| Piece                       | Where                                                               | Job                                                           |
| --------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------- |
| AppSec                      | `security/crowdsec-appsec`, from `appsec` in `app/helmrelease.yaml` | Scores the client and serves the challenge page               |
| Exemption overlay           | `appsec.configs` in `app/helmrelease.yaml`                          | Lists the hosts and paths that are never challenged           |
| WASM filter                 | `EnvoyExtensionPolicy` next to each protected route                 | Asks AppSec about each request and returns the challenge page |
| Static clusters and key env | `EnvoyProxy/edge` in `envoy-gateway/app/envoy.yaml`                 | Lets Envoy reach AppSec, and passes the key to the filter     |
| Key                         | `ExternalSecret/crowdsec-wasm` in `network`                         | Same 1Password field as the bouncer key                       |

The filter is `aarnaud/crowdsec-wasm-bouncer`. The `kdwils` bouncer still bans IP addresses on
every edge route. The filter runs only on the routes that have an `EnvoyExtensionPolicy`, and its
IP ban check is off.

### Why a WASM filter and not the bouncer

The `kdwils` bouncer needs `bodyToExtAuth` to pass the challenge answer to AppSec. Envoy answers
HTTP 413 when a body is larger than `maxRequestBytes`, and that rule wins over `failOpen`. On the
Forgejo host this would break `git push` and registry pushes. The WASM filter reads at most
`max_body_size_kb`, skips binary bodies, and streams the rest through.

### Add or change a protected route

1. Add an `EnvoyExtensionPolicy` for the HTTPRoute. Copy `forgejo/envoyextensionpolicy.yaml` in
   `external-endpoints/services/app/`. The policy must be in the namespace of the route.
2. Add the host to the overlay in `app/helmrelease.yaml`. A host that the overlay does not name is
   never challenged. Add its machine paths (API, webhooks, feeds) to the exempt rules for that
   host.
3. Bump the filter version in each policy. The `sha256` field is the checksum of the WASM module,
   not of the image. Apply the policy with a wrong value, then read the right value from the
   message in `.status.ancestors[].conditions[]` of the policy.

### Rules that bite

- List the AppSec configs by name. The wildcard `crowdsecurity/appsec-bot-*` also loads
  `appsec-bot-challenge-warn-experimental`, and `appsec-default` needs out-of-band rules that we
  do not install. Either one stops the AppSec pod with `no appsec-rules found`.
- The init container of the AppSec pod has a 50Mi memory limit in the chart. It registers with
  LAPI, hits the limit, and spins forever. A `postRenderers` patch raises the limit.
- The LAN (`10.`) and Frostlink (`40.233.88.33`) are exempt in the overlay. The `exemptIPs` of the
  bouncer do not apply to the filter.
- A phone on Tailscale is not an outside client. Test from the public path (see
  § Testing a ban from home).
- `failOpen` is on in the filter and the policy. If AppSec is down, nothing is challenged.

### Check it after a change

Run these with `--resolve git.dcunha.io:443:40.233.88.33` so that the request takes the public
path. A browser user agent and plain `curl` must both get the page titled `CrowdSec Challenge`.
These paths must not:

- `/swagger.v1.json` must return JSON with `info.title` equal to `Forgejo API`.
- `/api/v1/version`, `/api/v1/users/search`, `/api/v1/orgs` and `/api/v1/repos/<owner>/<repo>/topics`
  must return JSON.
- `/<owner>/<repo>.git/info/refs?service=git-upload-pack` must return the git advertisement, and
  `git clone` must work.
- `/v2/` must return 401 JSON.

### kubesearch needs `/swagger.v1.json`

kubesearch.dev lists repos that carry the topic `kubesearch` or `k8s-at-home`. It reads
non-GitHub repos from Epithet (`epithet.eno1.dev`), a search index of Forgejo, Gitea and GitLab
servers. Epithet must identify a server before it crawls it. It requests `/swagger.v1.json` and
needs JSON with the title `Forgejo API`. A challenge page is HTML, so Epithet answers `Unable to
identify Forge backend` and indexes nothing. The overlay exempts this path by path, not by user
agent, because anyone can fake a user agent. Everything else that Epithet reads is under
`/api/v1/`, which the overlay also exempts.

To register or re-register the server, send one request. Epithet indexes every public repo on the
server.

```bash
curl -s -X POST -H "content-type: application/json" -d '{"url":"https://git.dcunha.io"}' https://epithet.eno1.dev/v1/api/index_request
```

A reply of `queued for indexing` or `recently been indexed` means that it worked. A repo appears
in the index only when it is public, carries the topic, and received a push in the last 90 days.

## Simulation mode

`simulation.yaml` in `app/helmrelease.yaml` puts every local scenario in simulation. Agents
record alerts but create no bans. Only the community blocklist and manual `cscli` decisions
block. Review the simulated alerts before you turn simulation off:

```bash
kubectl exec -n security deploy/crowdsec-lapi -- cscli alerts list
```

Allowlist any false positive (a parser whitelist like `edge-whitelist.yaml`). Then set
`simulation: false`.

## Day-to-day commands

All run as `kubectl exec -n security deploy/crowdsec-lapi -- cscli …`.

| Task                    | `cscli` arguments                                        |
| ----------------------- | -------------------------------------------------------- |
| Is an IP banned?        | `decisions list --ip <ip>`                               |
| Unban an IP             | `decisions delete --ip <ip>`                             |
| Ban an IP by hand       | `decisions add --ip <ip> --duration 4h --reason "<why>"` |
| What fired recently     | `alerts list`                                            |
| Are bouncers connected  | `bouncers list`                                          |
| Engine and parser stats | `metrics`                                                |

The bouncer polls LAPI every 10s, so a new or deleted decision takes up to ~10s to apply.

## Testing a ban from home

Home traffic is exempt and never reaches Frostlink. Force the public path with `--resolve`:

```bash
curl -s -o /dev/null -w '%{http_code}\n' --resolve echo.dcunha.io:443:40.233.88.33 https://echo.dcunha.io/
```

Ban your WAN IP for 2 minutes with `decisions add`, expect `403`, then delete the decision and
expect `200`. A phone on Tailscale is not an outside client, because its DNS resolves through
home.

After `SecurityPolicy/edge` is first created, Envoy can take a minute or two to pick it up. A ban
test that ran immediately after the apply passed traffic, and the rerun blocked.

## Monitoring

- Dashboards: `crowdsec-overview` and `crowdsec-lapi` (the official v5 set of CrowdSec), and
  `crowdsec-bouncer` (from the bouncer chart repo).
- The LAPI ServiceMonitor is post-rendered with `honorLabels: true`. LAPI metrics carry their own
  `endpoint` label (`/v1/decisions`, …). Without `honorLabels`, the scrape overwrites that label
  with `endpoint="metrics"` and the LAPI dashboard shows nothing.
- The `lapi` variable of the LAPI dashboard lists every pod that exposes `cs_info`, agents
  included, and defaults to the first one, which is an agent. Pick the IP of the `crowdsec-lapi`
  pod, or most panels stay empty.
- Alerts: `app/prometheusrule.yaml` (LAPI and agents) and `bouncer/prometheusrule.yaml`.
- Envoy's side: `envoy_cluster_upstream_rq{envoy_cluster_name="securitypolicy/network/edge/extauth/0"}`.
