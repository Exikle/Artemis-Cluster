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
