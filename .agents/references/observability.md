# Reference: Observability — Artemis-Cluster

## Grafana Operator

- `GrafanaDashboard` namespace = Grafana folder name — always deploy GrafanaDashboards in their **app's** namespace (e.g. `rook-ceph`, `kopiur-system`), never in `default`
- `datasourceName` must exactly match the datasource name in the Grafana datasource CR — currently: `prometheus`, `alertmanager`, `victoria-logs`
- Stale GrafanaDashboards in `default` namespace (from old setups) override correct-namespace copies — delete them manually if folders appear wrong in Grafana

## ServiceMonitor / PodMonitor Bootstrap Gap

Apps deployed before kube-prometheus-stack (before the ServiceMonitor CRD existed) silently fail to create their monitors. After KPS is healthy, fix with:

```bash
flux reconcile hr <app> -n <namespace> --force
```

This is a one-time issue per cluster bootstrap.

## Rook-Ceph Metrics

Ceph cluster metrics (`ceph_health_status`, pool stats) come from the MGR on port 9283 via `rook-ceph-mgr` service — **not** from `rook-ceph-exporter` (per-daemon only).

The `ServiceMonitor` for this is manually managed in `rook-ceph/rook-ceph/app/servicemonitor.yaml` because the Rook operator cannot create it retroactively after the CRD gap.

## Suppressing Bundled Chart Resources

Some charts (e.g. victoria-logs) unconditionally bundle GrafanaDashboards with no per-resource disable flag. Suppress via HelmRelease postRenderer:

```yaml
postRenderers:
    - kustomize:
          patches:
              - target:
                    kind: GrafanaDashboard
                    name: <dashboard-name>
                patch: |
                    $patch: delete
                    apiVersion: grafana.integreatly.org/v1beta1
                    kind: GrafanaDashboard
                    metadata:
                      name: <dashboard-name>
```

## kromgo Badge Metrics

Available at `https://kromgo.dcunha.io/<metric>`:

`talos_version`, `kubernetes_version`, `flux_version`, `cluster_node_count`, `cluster_pod_count`, `cluster_cpu_usage`, `cluster_memory_usage`, `cluster_age_days`, `cluster_uptime_days`, `cluster_alert_count`

Config lives in `kubernetes/apps/observability/kromgo/app/resources/config.yaml`.

**Badge format**: always use shields.io endpoint format — direct SVG URLs get cached indefinitely by GitHub's camo proxy.

## chaski Notification Templates

`kubernetes/apps/observability/chaski/app/helmrelease.yaml` renders every Pushover
notification. Four payload shapes reach it, dispatched in this order by
`route-title` / `route-message` / `route-url`:

| Discriminator       | Sender                       | Templates   |
| ------------------- | ---------------------------- | ----------- |
| `payload.alerts`    | Alertmanager                 | `alert-*`   |
| `payload.eventType` | Sonarr / Radarr              | `arr-*`     |
| `payload.skill`     | hermes cron skills           | `hermes-*`  |
| (none)              | ad-hoc `{title,message,url}` | passthrough |

**Order is load-bearing.** `skill` is checked third so an Alertmanager or arr payload
that happened to carry a `skill` key still takes its own branch. Adding a fifth sender
means appending a branch, never reordering the existing ones.

### Why the hermes branch is shaped the way it is

The three hermes skills (`cluster-health`, `forgejo-pr-review`, `readme-sync`) are LLM
cron jobs. When they composed their own HTML message bodies, every run produced a
slightly different layout — different labels, different ordering, occasional raw
markdown. The fix is a strict split: **the skill supplies data, chaski supplies format.**
The skill POSTs `{skill, status, summary, stats{}, items[], url}` and nothing else.

Consequences that are deliberate:

- **The title contains no payload text at all.** `hermes-name` maps the skill slug to a
  fixed display name and `hermes-status` maps status to one of four fixed tokens, so the
  title is one of a small closed set and cannot be injected into. Pushover never renders
  HTML in titles, so keeping tags out of it matters.
- **Every model-supplied value passes through `hermes-text` / `hermes-word` /
  `hermes-slug` / `hermes-num`**, which apply `default` → `toString` → `trunc` → `html`.
  The `html` escaper is the text/template builtin — sprout has no equivalent, and
  `escapeHTML` / `htmlEscape` are _not_ defined. Without it a stray `<` in a PR title
  breaks Pushover's `format: html` rendering.
- **`stats` and `items` are type-guarded with `kindIs` before use.** `dig` and field
  access both _error_ when a key holds the wrong type (e.g. `stats` as a string), and a
  render error means the notification is dropped entirely — the exact case where you most
  want to hear from the job. The guards coerce a malformed value to an empty dict/list so
  a degraded notification still arrives.
- **Length is bounded per-field, not globally**, because truncating the composed body
  could cut a tag in half. Worst case (every field maxed, 12 items) renders at 861 chars,
  under Pushover's 1024 limit.
- **`hermes-url` drops anything not starting with `https://`**, so a hallucinated
  `javascript:` or internal URL never reaches the notification's action button.
- An unknown skill slug renders an `Unknown Skill` frame rather than erroring — a new
  skill that forgets to add its rows still notifies, visibly wrong rather than silent.

### Changing a template

Validate offline before committing; chaski checks snippet wiring at boot, so a typo'd
`{{ template }}` name takes the whole deployment down:

```bash
podman run --rm -v "$PWD:/c:z" ghcr.io/home-operations/chaski:latest \
  validate -c /c/chaski.yaml --payload /c/sample.json --route warning
```

`chaski.yaml` is `spec.values.config` lifted out of the HelmRelease with the apprise URL
swapped for `json://localhost/`. Render a sample for **all four** payload shapes — the
dispatch is one shared template, so a hermes edit can regress alertmanager.
