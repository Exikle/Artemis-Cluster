# Reference: Observability — Artemis-Cluster

## Grafana Operator

- `GrafanaDashboard` namespace = Grafana folder name — always deploy GrafanaDashboards in their **app's** namespace (e.g. `rook-ceph`, `kopiur-system`), never in `default`
- `datasourceName` must exactly match the datasource name in the Grafana datasource CR — currently: `prometheus`, `alertmanager`, `victoria-logs`
- Stale GrafanaDashboards in `default` namespace (from old setups) override correct-namespace copies — delete them manually if folders appear wrong in Grafana

## ServiceMonitor / PodMonitor Bootstrap Gap

Apps deployed before the VictoriaMetrics operator installed the `ServiceMonitor` CRD silently fail to create their monitors. (There is no kube-prometheus-stack here and never was — metrics are VictoriaMetrics à-la-carte under `observability/victoria/{operator,agent,app,alert,logs}`, and the VM operator converts `ServiceMonitor`/`VMNodeScrape` into its own scrape objects.) Once the operator is healthy, fix with:

```bash
flux reconcile hr <app> -n <namespace> --force
```

This is a one-time issue per cluster bootstrap.

## Kubelet / cAdvisor Scraping

**Nothing scrapes the kubelet unless we create it.** Every other target in this cluster is
discovered from a `ServiceMonitor` shipped by its own chart and converted by the VM operator.
The kubelet has no chart. The `victoria-metrics-k8s-stack` chart would have supplied the
objects, but this cluster assembles VictoriaMetrics à la carte — separate HelmReleases for the
operator, `VMAgent`, `VMSingle` and `VMAlert` — so they were never created.

Until 2026-08-21 that meant the cluster had **no `container_*` metrics at all**: no
`container_memory_working_set_bytes`, no `container_cpu_usage_seconds_total`, and therefore no
way to compute a p95 for any workload. It is not a subtle gap and it is easy to reintroduce —
`jfroy/flatops`, which uses the same à-la-carte layout, has it too.

Fixed by `victoria/agent/vmnodescrape-kubelet.yaml`: three `VMNodeScrape` objects for
`/metrics`, `/metrics/cadvisor` and `/metrics/resource`. The spec follows the `kubelet` block
of the upstream chart's `values.yaml`, which is where to look when it needs updating.

RBAC needs nothing — the operator already grants the VMAgent ServiceAccount `nodes/metrics`.

### Three things in that file that are load-bearing

**`honorTimestamps: false`.** cAdvisor exports stale timestamps; honouring them produces gaps
and out-of-order rows. Upstream sets it for the same reason
([VictoriaMetrics#4697](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/4697)).

**`labeldrop` of `(id|name)`.** These are the cgroup path and the container runtime id. They
are unique per container _restart_, so they fork the series on every restart for no query
value. Upstream drops them; keep it.

**`labeldrop` of `extensions_talos_dev_.*|tuppr_home_operations_com_.*|beta_kubernetes_io_.*`
— ours, not upstream's.** The blanket `labelmap __meta_kubernetes_node_label_(.+)` above it is
upstream's, and on Talos it drags in labels that _change_:

- `extensions.talos.dev/*` carries a version per system extension (`i915`, `intel-ucode`,
  `kata-containers`, …) and moves on every Talos or extension bump — which Renovate does
  regularly.
- `tuppr.home-operations.com/upgrading` is added and removed by tuppr **for the duration of an
  upgrade**.

Every one of those changes forks _every container series on that node_ into a new series. Node
identity is already carried by `node` and `instance`; node attributes are joinable from
`kube_node_labels`. Stable node labels (`topology_*`, `node_kubernetes_io_gpu*`, `bgppolicy`)
are deliberately kept — only the churning families are dropped.

### Cost

Measured before enabling: 787,985 active series, 12,515 samples/sec, 3.7 GiB of the 50 GiB
`VMSingle` PVC at 14d retention. cAdvisor across 250 pods / 307 containers adds roughly
75–85k series — about **+10%**. If that ever becomes a problem, the lever is dropping unused
cAdvisor metric families in `metricRelabelConfigs`, not shortening retention.

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
