# Reference: Observability — Artemis-Cluster

## Grafana Operator

- `GrafanaDashboard` namespace = Grafana folder name — always deploy GrafanaDashboards in their
  **app's** namespace (e.g. `rook-ceph`, `kopiur-system`), never in `default`
- There is **no `Grafana` CR and no `GrafanaFolder` CR** in this cluster. Grafana itself is an
  app-template HelmRelease (`observability/grafana`, Deployment `grafana-deployment`); the
  operator is present only to reconcile `GrafanaDatasource` and `GrafanaDashboard` objects.
- Stale GrafanaDashboards in `default` override correct-namespace copies. `default` is currently
  clean — if a folder looks wrong in Grafana, `kubectl get grafanadashboard -n default` first.

### `datasourceName` is the CR's `spec.datasource.name`, not the CR's own name

This is the single most common reason a dashboard renders with empty panels. Four datasources
exist and **two of them have a CR name that differs from the datasource name**:

| CR (`grafanadatasource` in `observability`) | `datasourceName` to use in a dashboard | Type                              |
| ------------------------------------------- | -------------------------------------- | --------------------------------- |
| `prometheus`                                | `prometheus`                           | `prometheus`                      |
| `alertmanager`                              | `alertmanager`                         | `alertmanager`                    |
| `victoria-logs`                             | **`VictoriaLogs`**                     | `victoriametrics-logs-datasource` |
| `victoriametrics`                           | **`VictoriaMetrics`**                  | `prometheus`                      |

`prometheus` and `victoriametrics` both point at
`http://victoria-metrics-server.observability.svc.cluster.local:8428` — the first is the
compatibility name most vendored dashboards expect, the second is the native-typed one. Either
works for metrics; do not "consolidate" them, vendored dashboards hardcode `prometheus`.

Confirm before writing a dashboard:

```bash
kubectl get grafanadatasource -A \
  -o custom-columns=CR:.metadata.name,NAME:.spec.datasource.name,TYPE:.spec.datasource.type
```

## ServiceMonitor / PodMonitor Bootstrap Gap

Apps deployed before the VictoriaMetrics operator installed the `ServiceMonitor` CRD silently
fail to create their monitors. Once the operator is healthy, fix with:

```bash
flux reconcile hr <app> -n <namespace> --force
```

This is a one-time issue per cluster bootstrap.

## What the metrics stack actually is

Metrics are VictoriaMetrics assembled à la carte under `observability/victoria/`. The VM operator
watches `ServiceMonitor`/`PodMonitor`/`PrometheusRule` and mirrors each into its own
`VMServiceScrape`/`VMPodScrape`/`VMRule`, so both APIs are live and a chart that ships either one
works unmodified.

| Directory   | What it is                                                                                                               | Resulting workload                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------- |
| `operator/` | `victoria-metrics-operator` chart                                                                                        | Deployment `vm-operator`              |
| `agent/`    | **plain manifests, no HelmRelease** — a `VMAgent` CR plus the kubelet `VMNodeScrape`s and the pantheon `VMStaticScrape`s | Deployment `vmagent-vmagent`          |
| `app/`      | `victoria-metrics-single` chart                                                                                          | StatefulSet `victoria-metrics-server` |
| `alert/`    | `victoria-metrics-alert` chart                                                                                           | Deployment `vmalert-server`           |
| `logs/`     | `victoria-logs-single` chart                                                                                             | StatefulSet `victoria-logs-server`    |

Two shapes to get right, because the names invite the wrong assumption:

- **There is no `VMSingle`, `VMAlert` or `VMAlertmanager` CR.** The metrics store and the ruler
  are ordinary chart workloads; `kubectl get vmsingle -A` returns nothing and that is correct.
  `VMAgent` is the only VM operator instance CR in the cluster.
- **Alertmanager is its own app-template HelmRelease** (`observability/alertmanager`,
  StatefulSet `alertmanager`), not bundled by any VM chart.

### kube-prometheus-stack was here, and left litter

A `kube-prometheus-stack` (chart 85.0.2) ran in `observability` until ~2026-05-16. Nothing in
`kubernetes/` references it any more, which is exactly why Flux will never prune what it left:

| Leftover                                                                         | Cost                     |
| -------------------------------------------------------------------------------- | ------------------------ |
| PVC `prometheus-kube-prometheus-stack-db-prometheus-kube-prometheus-stack-0`     | 50Gi `ceph-block`, Bound |
| PVC `alertmanager-kube-prometheus-stack-db-alertmanager-kube-prometheus-stack-0` | 1Gi `ceph-block`, Bound  |
| `VMRule` `kube-prometheus-stack-kube-apiserver-availability.rules`               | still evaluated          |
| `VMRule` `kube-prometheus-stack-kube-apiserver-burnrate.rules`                   | still evaluated          |

The VMRules carry `helm.toolkit.fluxcd.io/name: kube-prometheus-stack` labels and no
`ownerReferences`. They are orphans, not managed state — do not go looking for the manifest that
produces them. Deleting all four is safe and reclaims 51Gi of Ceph; it has not been done yet.

## Kubelet / cAdvisor Scraping

**Nothing scrapes the kubelet unless we create it.** Every other target in this cluster is
discovered from a `ServiceMonitor` shipped by its own chart and converted by the VM operator.
The kubelet has no chart. The `victoria-metrics-k8s-stack` chart would have supplied the
objects, but this cluster assembles VictoriaMetrics à la carte (see the table above), so they
were never created.

Until 2026-08-21 that meant the cluster had **no `container_*` metrics at all**: no
`container_memory_working_set_bytes`, no `container_cpu_usage_seconds_total`, and therefore no
way to compute a p95 for any workload. It is not a subtle gap and it is easy to reintroduce —
`jfroy/flatops`, which uses the same à-la-carte layout, has it too.

Fixed by `victoria/agent/vmnodescrape-kubelet.yaml`: three `VMNodeScrape` objects — `kubelet`,
`kubelet-cadvisor`, `kubelet-resource` — for `/metrics`, `/metrics/cadvisor` and
`/metrics/resource`. The spec follows the `kubelet` block of the upstream chart's `values.yaml`,
which is where to look when it needs updating.

**All three relabel to `job="kubelet"`.** The `VMNodeScrape` object names are not job names, so
`{job="kubelet-cadvisor"}` matches nothing and looks like the scrape is broken. Query
`container_memory_working_set_bytes{job="kubelet"}`. Confirm the scrape is alive with
`count(container_memory_working_set_bytes)` — currently ~1,119 series.

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
`victoria-metrics-server` PVC at 14d retention. cAdvisor across 250 pods / 307 containers was
projected to add 75–85k series.

Measured after, 2026-08-21: **561,362 active series**, 18,829 samples/sec, 8.07 GiB of the 50 GiB
PVC, `container_*` accounting for **68,319 series** — inside the projection. Series count fell
overall because unrelated churning label families were dropped in the same window; do not read
the drop as cAdvisor being free.

If it ever becomes a problem, the lever is dropping unused cAdvisor metric families in
`metricRelabelConfigs`, not shortening retention. Re-measure with:

```bash
kubectl port-forward -n observability svc/victoria-metrics-server 18428:8428
curl -s 'localhost:18428/api/v1/query?query=sum(vm_cache_entries{type="storage/hour_metric_ids"})'
```

## prometheus-adapter is a cluster-wide dependency, not an observability nicety

`observability/prometheus-adapter` backs the **`v1beta1.external.metrics.k8s.io` APIService** —
it is the only provider of it. Every `components/zeroscaler` HPA (eleven apps: ten in `media`,
plus `default/komga`) scales on an `External` metric:

```text
probe_success{job="blackbox-tcp"}  →  target value 1  →  minReplicas 0 / maxReplicas 1
```

So the wake-up path is a chain, and any link breaking parks eleven apps at zero replicas:

```text
blackbox-exporter → vmagent → victoria-metrics-server → prometheus-adapter → HPA → Deployment
```

`prometheus-adapter` reads `http://victoria-metrics-server.observability.svc.cluster.local`
(port 80, no `:8428` — the chart's own default service port, not the StatefulSet's). It is
otherwise invisible: no route, no dashboard, and nothing alerts on the APIService going
`False`. Diagnose a cluster-wide "everything in media is down" with:

```bash
kubectl get apiservice v1beta1.external.metrics.k8s.io
kubectl get hpa -A
```

`AVAILABLE=False` on that APIService, or `<unknown>/1` in the HPA `TARGETS` column, means the
adapter, not the apps. See `.agents/references/media-stack.md` § Scale-to-zero.

## Other observability workloads worth knowing exist

Not covered elsewhere in this file, and easy to mistake for something they are not:

| App                 | What it is                                                                                                    |
| ------------------- | ------------------------------------------------------------------------------------------------------------- |
| `siren`             | Alertmanager web UI at `siren.dcunha.io` (internal). Reads the shared Alertmanager; holds no state of its own |
| `silence-operator`  | Declarative Alertmanager silences as CRs — scraped via a `VMPodScrape`, not a Service                         |
| `gatus-sidecar`     | External/black-box status page at `status.dcunha.io`; source of the `core_*` kromgo badges                    |
| `blackbox-exporter` | Probe target for `VMProbe` `https`/`icmp`/`tcp` — and the wake signal for every zeroscaler app                |

## Rook-Ceph Metrics

Ceph cluster metrics (`ceph_health_status`, pool stats) come from the MGR on port 9283 via the
`rook-ceph-mgr` Service (`http-metrics`) — **not** from `rook-ceph-exporter`, which is per-daemon
only. Both are scraped; only one carries cluster-level state.

The `ServiceMonitor` for this is manually managed in
`rook-ceph/rook-ceph/app/servicemonitor.yaml` because the Rook operator cannot create it
retroactively after the CRD gap.

## Suppressing Bundled Chart Resources

Some charts (e.g. victoria-logs) unconditionally bundle GrafanaDashboards with no per-resource
disable flag. Suppress via HelmRelease postRenderer:

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

**The path is `/badges/<id>`, not `/<id>`.** A bare `https://kromgo.dcunha.io/cluster_pod_count`
returns `404 page not found`; `https://kromgo.dcunha.io/badges/cluster_pod_count` returns the SVG.
The root path serves a gallery page that prints a copy-paste Markdown snippet per badge — open it
rather than guessing an id.

Fourteen badges, from `kubernetes/apps/observability/kromgo/app/resources/config.yaml`:

| Group    | ids                                                                                                           |
| -------- | ------------------------------------------------------------------------------------------------------------- |
| Versions | `talos_version`, `kubernetes_version`, `flux_version`, `renovate_status`                                      |
| Cluster  | `cluster_node_count`, `cluster_pod_count`, `cluster_cpu_usage`, `cluster_memory_usage`, `cluster_alert_count` |
| Age      | `cluster_birth_age`, `cluster_uptime_age`                                                                     |
| Gatus    | `core_ping`, `core_status_page`, `core_heartbeat`                                                             |

| Wrong (and what older docs said) | Right                |
| -------------------------------- | -------------------- |
| `cluster_age_days`               | `cluster_birth_age`  |
| `cluster_uptime_days`            | `cluster_uptime_age` |
| `https://kromgo.dcunha.io/<id>`  | `…/badges/<id>`      |

`?format=json` on the same path returns `{id,title,value,color,result}` — useful for scripting a
check without parsing SVG.

**kromgo renders the SVG itself.** The repo README embeds those URLs directly
(`![Age](https://kromgo.dcunha.io/badges/cluster_birth_age)`), not shields.io endpoint URLs. An
older note in this file said to always go through shields.io endpoint format; that no longer
describes what the repo does. The underlying caveat is still real — GitHub's camo proxy caches a
direct SVG aggressively — so treat badge values as approximate on GitHub mirrors, and read live
values from `?format=json`.

The gatus-backed badges (`core_*`) depend on `gatus-sidecar`; `renovate_status` reads
`kube_job_status_succeeded` in `kube-system`. Both go stale silently if their source stops
reporting — the badge keeps rendering the last scraped value's colour.

## Scrape coverage — where the holes are

`vmagent` reports every target healthy (`up == 0` returns nothing), but healthy targets are only
the ones that exist. Two namespaces run workloads that export metrics nobody collects:

| Namespace  | Scrape objects        | Consequence                                                           |
| ---------- | --------------------- | --------------------------------------------------------------------- |
| `security` | none until 2026-08-21 | 12 pocket-id-operator alert rules could never fire — see below        |
| `cortex`   | 6 targets, all up     | hermes, searxng and the eleven MCP servers remain unmonitored (#1837) |

Check whether a namespace is covered at all before trusting an alert in it:

```bash
kubectl get vmservicescrape,vmpodscrape -n <namespace>
```

### The `security` hole — a chart that ships rules and scrapes behind separate flags

`security/pocket-id-operator` ships **12 alert rules**, including
`PocketIDOIDCClientRotationFailing`, `PocketIDOIDCClientRotationOverdue` and
`PocketIDExternalDeletions`. Every metric they reference was absent from VictoriaMetrics, so a
client-secret rotation could have failed indefinitely with nothing firing.

An earlier revision of this file said "13 rules". The chart's
`templates/monitoring/prometheusrule.yaml` renders **12** — count them with
`kubectl -n security get prometheusrule pocket-id-operator -o json | jq '[.spec.groups[].rules[]] | length'`.

**The mechanism is a values asymmetry, not a missing manifest.** In chart 0.14.0:

| Value                            | Default | Effect                                                              |
| -------------------------------- | ------- | ------------------------------------------------------------------- |
| `metrics.prometheusRule.enabled` | `true`  | rules render whenever the `monitoring.coreos.com/v1` CRD exists     |
| `metrics.enabled`                | `false` | operator starts with `--metrics-bind-address=0`; no metrics Service |
| `metrics.serviceMonitor.enabled` | `false` | no ServiceMonitor                                                   |

So the chart alerts by default and scrapes by opt-in. Installing it unmodified produces a
PrometheusRule whose every expression is against a metrics server the same chart just disabled.
`kubectl get vmrule` looks healthy; the rules are inert. **Any chart that gates rules and
scraping on different flags can do this — check both before trusting an alert it shipped.**

Fixed by setting `metrics.enabled: true` and `metrics.serviceMonitor.enabled: true` in
`security/pocket-id/operator/helmrelease.yaml`. That renders Service
`pocket-id-operator-metrics-service` on `:8080` and a ServiceMonitor the VM operator mirrors to a
VMServiceScrape.

**The job label is the Service name.** vmagent names service-scrape jobs after the Service, so
the resulting job is `pocket-id-operator-metrics-service` — which is what makes the two rules
written as `job=~".*pocket-id-operator.*"` (`PocketIDReconcileErrors`, `PocketIDWorkQueueBackup`,
both on controller-runtime builtins) match. A `jobLabel:` naming a label the Service does not
carry is silently ignored and the job falls back to the Service name anyway; `grafana` in this
cluster is job `grafana-service` for exactly that reason.

### What actually exports metrics in `security`

| Workload             | Endpoint                               | Scrape                                            |
| -------------------- | -------------------------------------- | ------------------------------------------------- |
| `pocket-id-operator` | `:8080/metrics` once `metrics.enabled` | chart ServiceMonitor via `metrics.serviceMonitor` |
| `pocket-id`          | Service port `metrics` `:9464`         | `pocket-id/instance/servicemonitor.yaml` (ours)   |
| `lldap`              | none                                   | —                                                 |
| `tinyauth`           | none                                   | —                                                 |

lldap and tinyauth **serve their SPA at `/metrics`** — `wget -qO- :17170/metrics` returns
`<!doctype html>`, not an exposition. There is nothing to scrape; do not add monitors for them.

The pocket-id instance ServiceMonitor is hand-written because the chart's
`templates/instance/instance-servicemonitor.yaml` only renders when the chart owns the instance
(`instance.enabled`). This cluster deploys the `PocketIDInstance` itself from
`pocket-id/instance/`, so that template never fires. **Its selector would not have worked
anyway** — it matches `app.kubernetes.io/name` + `app.kubernetes.io/instance`, and the Service
the operator creates carries only `managed-by: pocket-id-operator`. Ours selects on that.

### Finding the next dead alert

An alert whose metric has no scrape source produces no series, so diff the metric names in every
rule against the names VictoriaMetrics actually knows:

```bash
kubectl port-forward -n observability svc/victoria-metrics-server 18428:8428 &
export LC_ALL=C
comm -23 \
  <(kubectl get vmrule -A -o json | jq -r '.items[].spec.groups[].rules[].expr' \
      | grep -oE '\b[a-z_][a-z0-9_]*_[a-z0-9_]+\b' | sort -u) \
  <(curl -s localhost:18428/api/v1/label/__name__/values | jq -r '.data[]' | sort -u)
```

`LC_ALL=C` is required — `comm` rejects the default locale's collation. The output is a
superset: label names (`pool_name`, `code_verb`), label _values_ (`min_spacing`,
`window_missed`) and multi-word PromQL keywords (`clamp_max`, `group_left`) all match the same
identifier shape. Read it as a candidate list, not a verdict — a contiguous block of one
`<subsystem>_*` family, as the eleven `pocketid_operator_*` names formed, is the real signal.
Currently ~61 lines; the remainder are Ceph nvmeof/rbd-mirror and cert-manager families that
genuinely do not exist on this cluster and whose rules come from vendored rule sets.

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
