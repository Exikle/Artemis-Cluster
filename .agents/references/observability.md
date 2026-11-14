# Reference: Observability — home-infra

## Grafana Operator

- The `GrafanaDashboard` namespace is the Grafana folder name. Always deploy GrafanaDashboards in
  the namespace of their **app** (for example `miroir-system` or `kopiur-system`), never in
  `default`.
- Grafana **is** a `Grafana` CR (`observability/grafana/instance/grafana.yaml`), which the operator
  reconciles into Deployment `grafana-deployment`. It is not an app-template HelmRelease. There is
  no `GrafanaFolder` CR.
- Grafana is stateless. Its database is the shared Postgres (`grafana` on `postgres-rw`,
  `sslmode=verify-full`), and `/var/lib/grafana` is an `emptyDir`. There is no PVC. Everything that
  Grafana serves comes from CRDs, the admin password comes from an ExternalSecret, and users come
  from Pocket-ID OIDC. A wiped pod loses nothing. Plugins re-download on start.
- The one thing that is not in Git is the `grafana-mcp` service account and its token. The token
  value lives in 1Password, but the account itself lives in the Postgres database. If anyone ever
  rebuilds that database, recreate the service account in the UI and update
  `GRAFANA_SERVICE_ACCOUNT_TOKEN`, or the Grafana MCP server breaks.
- Stale GrafanaDashboards in `default` override correct-namespace copies. `default` is currently
  clean. If a folder looks wrong in Grafana, run `kubectl get grafanadashboard -n default` first.

### `datasourceName` is the CR's `spec.datasource.name`, not the CR's own name

This is the most common reason that a dashboard renders with empty panels. Four datasources exist,
and **two of them have a CR name that differs from the datasource name**:

| CR (`grafanadatasource` in `observability`) | `datasourceName` to use in a dashboard | Type                              |
| ------------------------------------------- | -------------------------------------- | --------------------------------- |
| `prometheus`                                | `prometheus`                           | `prometheus`                      |
| `alertmanager`                              | `alertmanager`                         | `alertmanager`                    |
| `victoria-logs`                             | **`VictoriaLogs`**                     | `victoriametrics-logs-datasource` |
| `victoriametrics`                           | **`VictoriaMetrics`**                  | `prometheus`                      |

`prometheus` and `victoriametrics` both point at
`http://victoria-metrics-server.observability.svc.cluster.local:8428`. The first is the
compatibility name that most vendored dashboards expect. The second is the native-typed one. Either
works for metrics. Do not "consolidate" them, because vendored dashboards hardcode `prometheus`.

Before you write a dashboard, make sure that the names are right:

```bash
kubectl get grafanadatasource -A \
  -o custom-columns=CR:.metadata.name,NAME:.spec.datasource.name,TYPE:.spec.datasource.type
```

## ServiceMonitor / PodMonitor Bootstrap Gap

Apps that were deployed before the VictoriaMetrics operator installed the `ServiceMonitor` CRD
silently fail to create their monitors. After the operator is healthy, fix this with:

```bash
flux reconcile hr <app> -n <namespace> --force
```

This is a one-time issue per cluster bootstrap.

## What the metrics stack actually is

Metrics are VictoriaMetrics, assembled piece by piece under `observability/victoria/`. The VM
operator watches `ServiceMonitor`, `PodMonitor` and `PrometheusRule`, and it mirrors each into its
own `VMServiceScrape`, `VMPodScrape` or `VMRule`. So both APIs are live, and a chart that ships
either one works unmodified.

| Directory   | What it is                                                                                                               | Resulting workload                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------- |
| `operator/` | `victoria-metrics-operator` chart                                                                                        | Deployment `vm-operator`              |
| `agent/`    | **plain manifests, no HelmRelease** — a `VMAgent` CR plus the kubelet `VMNodeScrape`s and the pantheon `VMStaticScrape`s | Deployment `vmagent-vmagent`          |
| `app/`      | `victoria-metrics-single` chart                                                                                          | StatefulSet `victoria-metrics-server` |
| `alert/`    | **plain manifests, no HelmRelease** — a `VMAlert` CR plus the `cluster-baseline` `VMRule`                                | Deployment `vmalert-vmalert`          |
| `logs/`     | `victoria-logs-single` chart                                                                                             | StatefulSet `victoria-logs-server`    |

The names invite a wrong assumption, so keep these two shapes in mind:

- There is no `VMSingle` or `VMAlertmanager` CR. The metrics store is an ordinary chart workload.
  `kubectl get vmsingle -A` returns nothing, and that is correct. `VMAgent` and `VMAlert` are the
  only VM operator instance CRs in the cluster.
- Alertmanager is its own app-template HelmRelease (`observability/alertmanager`, StatefulSet
  `alertmanager`). No VM chart bundles it.

### kube-prometheus-stack was here, and left litter

A `kube-prometheus-stack` ran in `observability` until about 2026-05-16. Nothing in `clusters/artemis/kubernetes/`
references it any more, which is exactly why Flux will never prune what it left:

| Leftover                                                           | Cost            |
| ------------------------------------------------------------------ | --------------- |
| `VMRule` `kube-prometheus-stack-kube-apiserver-availability.rules` | still evaluated |
| `VMRule` `kube-prometheus-stack-kube-apiserver-burnrate.rules`     | still evaluated |

The VMRules carry `helm.toolkit.fluxcd.io/name: kube-prometheus-stack` labels and no
`ownerReferences`. Deleting them is
[#2764](https://git.dcunha.io/Exikle/home-infra/issues/2764). They are orphans, not managed
state. Do not look for the manifest that produces them. Deleting them is safe, and nobody has done
it yet.

### Where the `monitoring.coreos.com` CRDs come from

The chart name survives in one live place, and it is not a deployment. `clusters/artemis/bootstrap/helmfile.d/00-crds.yaml`
carries a `kube-prometheus-stack` release that is **never installed**. `base` renders it and keeps
`kind: CustomResourceDefinition`. It throws the rest away: a `Prometheus` CR, an `Alertmanager`, the
Deployments, a DaemonSet, both operator webhooks and the PrometheusRules. That one `yq` filter is
the only thing that keeps a second metrics stack out of the cluster.

It is load-bearing, because nothing under `clusters/artemis/kubernetes/` installs those CRDs. `crds.enabled: true` of
vm-operator ships the **VictoriaMetrics** CRDs. Its `disable_prometheus_converter: false` only makes
it _watch_ `ServiceMonitor`, `PodMonitor`, `PrometheusRule` and `Probe`, which the repo uses
everywhere. Registering those kinds is the job of bootstrap alone.

The CRDs in the cluster today are still the CRDs of the dead release (field manager `helm-controller`,
`helm.toolkit.fluxcd.io/name: kube-prometheus-stack`). Nothing has re-applied them since about
2026-05-16, so a Renovate bump on that chart version changes **nothing live**. It only picks which
CRD schemas the next rebuild installs.

## Kubelet / cAdvisor Scraping

Nothing scrapes the kubelet unless we create the scrape. Every other target in this cluster is
discovered from a `ServiceMonitor` that its own chart ships, and the VM operator converts it. The
kubelet has no chart. The `victoria-metrics-k8s-stack` chart would have supplied the objects, but
this cluster assembles VictoriaMetrics piece by piece (see the table above), so nobody created them.

Without them, the cluster has **no `container_*` metrics at all**. It has no
`container_memory_working_set_bytes`, no `container_cpu_usage_seconds_total`, and therefore no way
to compute a p95 for any workload. It is easy to reintroduce this fault.

`victoria/agent/vmnodescrape-kubelet.yaml` supplies them. It holds three `VMNodeScrape` objects,
`kubelet`, `kubelet-cadvisor` and `kubelet-resource`, for `/metrics`, `/metrics/cadvisor` and
`/metrics/resource`. The spec follows the `kubelet` block of the `values.yaml` of the upstream chart.
Look there when the spec needs an update.

All three relabel to `job="kubelet"`. The `VMNodeScrape` object names are not job names, so
`{job="kubelet-cadvisor"}` matches nothing and looks like the scrape is broken. Query
`container_memory_working_set_bytes{job="kubelet"}`. To make sure that the scrape is alive, run
`count(container_memory_working_set_bytes)`.

RBAC needs nothing. The operator already grants `nodes/metrics` to the VMAgent ServiceAccount.

### Three things in that file that are load-bearing

`honorTimestamps: false`: cAdvisor exports stale timestamps. If Flux honors them, they produce gaps
and out-of-order rows. Upstream sets it for the same reason
([VictoriaMetrics#4697](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/4697)).

`labeldrop` of `(id|name)`: These are the cgroup path and the container runtime id. They are unique
per container _restart_, so they fork the series on every restart for no query value. Upstream drops
them. Keep the drop.

`labeldrop` of `extensions_talos_dev_.*|tuppr_home_operations_com_.*|beta_kubernetes_io_.*`: This
one is ours, not upstream's. The blanket `labelmap __meta_kubernetes_node_label_(.+)` above it is
upstream's, and on Talos it drags in labels that _change_:

- `extensions.talos.dev/*` carries a version per system extension (`i915`, `intel-ucode`,
  `kata-containers`, …). It moves on every Talos or extension bump, which Renovate does regularly.
- `tuppr.home-operations.com/upgrading`: tuppr adds and removes it **for the duration of an
  upgrade**.

Every one of those changes forks _every container series on that node_ into a new series. The labels
`node` and `instance` already carry the node identity, and you can join node attributes from
`kube_node_labels`. The config deliberately keeps stable node labels (`topology_*`,
`node_kubernetes_io_gpu*`, `bgppolicy`). It drops only the churning families.

### Cost

cAdvisor adds tens of thousands of series. If that ever becomes a problem, the lever is to drop
unused cAdvisor metric families in `metricRelabelConfigs`, not to shorten retention. Re-measure
with:

```bash
kubectl port-forward -n observability svc/victoria-metrics-server 18428:8428
curl -s 'localhost:18428/api/v1/query?query=sum(vm_cache_entries{type="storage/hour_metric_ids"})'
```

## prometheus-adapter is a cluster-wide dependency, not an observability nicety

`observability/prometheus-adapter` backs the **`v1beta1.external.metrics.k8s.io` APIService**. It is
the only provider of it. Every `components/zeroscaler` HPA scales on an `External` metric. For the
current set, which spans more than one namespace, run `grep -rln 'components/zeroscaler' clusters/artemis/kubernetes/apps/`.

```text
probe_success{job="blackbox-tcp"}  →  target value 1  →  minReplicas 0 / maxReplicas 1
```

So the wake-up path is a chain. If any link breaks, it parks every zeroscaled app at zero replicas
simultaneously:

```text
blackbox-exporter → vmagent → victoria-metrics-server → prometheus-adapter → HPA → Deployment
```

`prometheus-adapter` reads `http://victoria-metrics-server.observability.svc.cluster.local` (port
80, no `:8428`; that is the default service port of the chart, not the port of the StatefulSet). It
is otherwise invisible: it has no route and no dashboard, and nothing alerts when the APIService goes
`False`. To diagnose a cluster-wide "everything in media is down", run:

```bash
kubectl get apiservice v1beta1.external.metrics.k8s.io
kubectl get hpa -A
```

`AVAILABLE=False` on that APIService, or `<unknown>/1` in the HPA `TARGETS` column, means that the
adapter is the fault, not the apps. See `.agents/references/media-stack.md` § Scale-to-zero.

### blackbox-exporter must never run BestEffort

It is the head of that chain, and one pod serves the whole cluster. With no resource requests, it
ran BestEffort. CPU contention on a busy node starved its probe goroutines until it missed its own
liveness probe. That took `probe_success` with it and idled every scale-to-zero app at once. So the
HelmRelease sets **CPU and memory requests** (a guaranteed share) and deliberately sets **no CPU
limit**, so the exporter can still burst through a probe sweep without throttling. Do not "tidy" a
CPU limit back in.

## Other observability workloads worth knowing exist

This file does not cover them elsewhere, and it is easy to mistake them for something they are not:

| App                 | What it is                                                                                                                                                                                                                                       |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `siren`             | Alertmanager web UI at `siren.dcunha.io` (internal). Reads the shared Alertmanager; holds no state of its own                                                                                                                                    |
| `silence-operator`  | Declarative Alertmanager silences as CRs — scraped via a `VMPodScrape`, not a Service                                                                                                                                                            |
| `gatus-sidecar`     | Not a status page any more — only `gatus-remote-reader`, the read-only account Frostlink's Gatus uses to generate checks from Artemis's routes. `status.dcunha.io` runs on Frostlink since 2026-10-03: see the Frostlink repo's `status-page.md` |
| `blackbox-exporter` | Probe target for `VMProbe` `https`/`icmp`/`tcp` — and the wake signal for every zeroscaler app                                                                                                                                                   |

## Alert-rule choices that look like omissions

| Rule / silence                                                        | Why it is written that way                                                                                                                                                                                                                                                                                                                            |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No CNPG alert on `cnpg_pg_stat_archiver_seconds_since_last_archival`  | An idle database skips the `archive_timeout`-forced WAL switch entirely, so the metric climbs past `archive_timeout` with nothing wrong — a cluster was observed at ~32m against a 900s timeout with zero failures. `cnpg_collector_pg_wal_archive_status{value="ready"} > 0` is the direct backlog signal and does not false-fire on a quiet cluster |
| `SmartDeviceMediaErrors` uses `delta()`, not `increase()`             | `smartctl_device_media_errors` is a gauge; `increase()` only applies to counters                                                                                                                                                                                                                                                                      |
| `SmartDeviceAvailableSpareUnderThreshold` compares the two raw values | Both are percentages (spare 100, threshold 10), not 0–1 ratios, so no scaling is needed                                                                                                                                                                                                                                                               |
| Permanent `pantheon-memory-high` silence                              | `pantheon` (the Proxmox host) consistently runs at ~94% — a hardware limit, not actionable                                                                                                                                                                                                                                                            |

## Suppressing Bundled Chart Resources

Some charts (for example victoria-logs) unconditionally bundle GrafanaDashboards, with no
per-resource disable flag. Suppress them with a HelmRelease postRenderer:

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

The path is `/badges/<id>`, not `/<id>`. A bare `https://kromgo.dcunha.io/cluster_pod_count` returns
`404 page not found`. `https://kromgo.dcunha.io/badges/cluster_pod_count` returns the SVG. The root
path serves a gallery page that prints a copy-paste Markdown snippet per badge. Open it instead of
you guessing an id.

The ids are in `clusters/artemis/kubernetes/apps/observability/kromgo/app/resources/config.yaml`
(`grep -n 'id:' <that file>`):

| Group    | ids                                                                                                           |
| -------- | ------------------------------------------------------------------------------------------------------------- |
| Versions | `talos_version`, `kubernetes_version`, `flux_version`, `renovate_status`                                      |
| Cluster  | `cluster_node_count`, `cluster_pod_count`, `cluster_cpu_usage`, `cluster_memory_usage`, `cluster_alert_count` |
| Age      | `cluster_birth_age`, `cluster_uptime_age`                                                                     |
| Gatus    | `core_ping`, `core_status_page`, `core_heartbeat`, `internal_truenas`, `internal_pve`                         |

| Wrong (and what older docs said) | Right                |
| -------------------------------- | -------------------- |
| `cluster_age_days`               | `cluster_birth_age`  |
| `cluster_uptime_days`            | `cluster_uptime_age` |
| `https://kromgo.dcunha.io/<id>`  | `…/badges/<id>`      |

`?format=json` on the same path returns `{id,title,value,color,result}`. Use it to script a check
without you parsing SVG.

kromgo renders the SVG itself. The repo README embeds those URLs directly
(`![Age](https://kromgo.dcunha.io/badges/cluster_birth_age)`), not shields.io endpoint URLs. The camo
proxy of GitHub caches a direct SVG aggressively. Treat badge values as approximate on GitHub
mirrors, and read live values from `?format=json`.

The gatus-backed badges (`core_*`) depend on the Gatus of Frostlink, which `vmstaticscrape-gatus.yaml`
scrapes. `renovate_status` reads `kube_job_status_succeeded` in `kube-system`. Both go stale
silently if their source stops reporting. The badge keeps rendering the color of the last scraped
value.

## Scrape coverage — where the holes are

`vmagent` reports every target healthy (`up == 0` returns nothing), but healthy targets are only the
targets that exist. Namespaces can run workloads that export metrics that nobody collects, so their
shipped alert rules can never fire. Before you trust an alert in a namespace, check whether the
namespace is covered at all:

```bash
kubectl get vmservicescrape,vmpodscrape -n <namespace>
```

Known uncovered: `cortex` hermes and most MCP servers (#1837).

### The `security` hole — a chart that ships rules and scrapes behind separate flags

`security/pocket-id-operator` ships alert rules, including `PocketIDOIDCClientRotationFailing`,
`PocketIDOIDCClientRotationOverdue` and `PocketIDExternalDeletions`. Every metric that they
reference was absent from VictoriaMetrics, so a client-secret rotation could have failed
indefinitely with nothing firing.

Count the rules with
`kubectl -n security get prometheusrule pocket-id-operator -o json | jq '[.spec.groups[].rules[]] | length'`.

The mechanism is an asymmetry in the values, not a missing manifest. In chart 0.14.0:

| Value                            | Default | Effect                                                              |
| -------------------------------- | ------- | ------------------------------------------------------------------- |
| `metrics.prometheusRule.enabled` | `true`  | rules render whenever the `monitoring.coreos.com/v1` CRD exists     |
| `metrics.enabled`                | `false` | operator starts with `--metrics-bind-address=0`; no metrics Service |
| `metrics.serviceMonitor.enabled` | `false` | no ServiceMonitor                                                   |

So the chart alerts by default and scrapes by opt-in. If you install it unmodified, it produces a
PrometheusRule whose every expression is against a metrics server that the same chart just disabled.
`kubectl get vmrule` looks healthy, but the rules are inert. Any chart that gates rules and scraping
on different flags can do this. Check both flags before you trust an alert that it shipped.

The fix is to set `metrics.enabled: true` and `metrics.serviceMonitor.enabled: true` in
`security/pocket-id/operator/helmrelease.yaml`. That renders Service
`pocket-id-operator-metrics-service` on `:8080` and a ServiceMonitor that the VM operator mirrors to
a VMServiceScrape.

The job label is the Service name. vmagent names service-scrape jobs after the Service, so the
resulting job is `pocket-id-operator-metrics-service`. That is what makes the two rules written as
`job=~".*pocket-id-operator.*"` (`PocketIDReconcileErrors`, `PocketIDWorkQueueBackup`, both on
controller-runtime builtins) match. If a `jobLabel:` names a label that the Service does not carry,
vmagent silently ignores it, and the job falls back to the Service name anyway. `grafana` in this
cluster is job `grafana-service` for exactly that reason.

### What actually exports metrics in `security`

| Workload             | Endpoint                               | Scrape                                            |
| -------------------- | -------------------------------------- | ------------------------------------------------- |
| `pocket-id-operator` | `:8080/metrics` once `metrics.enabled` | chart ServiceMonitor via `metrics.serviceMonitor` |
| `pocket-id`          | Service port `metrics` `:9464`         | `pocket-id/instance/servicemonitor.yaml` (ours)   |
| `lldap`              | none                                   | —                                                 |
| `tinyauth`           | none                                   | —                                                 |

lldap and tinyauth **serve their SPA at `/metrics`**. `wget -qO- :17170/metrics` returns
`<!doctype html>`, not an exposition. There is nothing to scrape. Do not add monitors for them.

The pocket-id instance ServiceMonitor is hand-written, because the chart template
`templates/instance/instance-servicemonitor.yaml` renders only when the chart owns the instance
(`instance.enabled`). This cluster deploys the `PocketIDInstance` itself from `pocket-id/instance/`,
so that template never fires. Its selector would not have worked anyway. It matches
`app.kubernetes.io/name` + `app.kubernetes.io/instance`, and the Service that the operator creates
carries only `managed-by: pocket-id-operator`. Ours selects on that.

### Finding the next dead alert

An alert whose metric has no scrape source produces no series. So diff the metric names in every
rule against the names that VictoriaMetrics actually knows:

```bash
kubectl port-forward -n observability svc/victoria-metrics-server 18428:8428 &
export LC_ALL=C
comm -23 \
  <(kubectl get vmrule -A -o json | jq -r '.items[].spec.groups[].rules[].expr' \
      | grep -oE '\b[a-z_][a-z0-9_]*_[a-z0-9_]+\b' | sort -u) \
  <(curl -s localhost:18428/api/v1/label/__name__/values | jq -r '.data[]' | sort -u)
```

`LC_ALL=C` is required, because `comm` rejects the collation of the default locale. The output is a
superset. Label names (`pool_name`, `code_verb`), label _values_ (`min_spacing`, `window_missed`)
and multi-word PromQL keywords (`clamp_max`, `group_left`) all match the same identifier shape. Read
the output as a candidate list, not a verdict. A contiguous block of one `<subsystem>_*` family is
the real signal. The eleven `pocketid_operator_*` names formed such a block. The remaining names are
families that genuinely do not exist on this cluster, and their rules come from vendored rule sets.

## chaski Notification Templates

`clusters/artemis/kubernetes/apps/observability/chaski/app/helmrelease.yaml` renders every Pushover notification.
Four payload shapes reach it. `route-title`, `route-message` and `route-url` dispatch them in this
order:

| Discriminator       | Sender                       | Templates   |
| ------------------- | ---------------------------- | ----------- |
| `payload.alerts`    | Alertmanager                 | `alert-*`   |
| `payload.eventType` | Sonarr / Radarr              | `arr-*`     |
| `payload.skill`     | hermes cron skills           | `hermes-*`  |
| (none)              | ad-hoc `{title,message,url}` | passthrough |

The order is load-bearing. The dispatch checks `skill` third, so an Alertmanager or arr payload that
happens to carry a `skill` key still takes its own branch. To add a fifth sender, append a branch.
Never reorder the existing ones.

### Why the hermes branch is shaped the way it is

The two hermes skills (`cluster-health`, `readme-sync`) are LLM cron jobs. When they composed their
own HTML message bodies, every run produced a slightly different layout: different labels, different
ordering, and occasional raw markdown. The fix is a strict split. The skill supplies data, and chaski
supplies format. The skill POSTs `{skill, status, summary, stats{}, items[], url}` and nothing else.

These consequences are deliberate:

- The title contains no payload text at all. `hermes-name` maps the skill slug to a fixed display
  name, and `hermes-status` maps status to one of four fixed tokens. So the title is one of a small
  closed set, and nobody can inject into it. Pushover never renders HTML in titles, so it matters
  that tags stay out of the title.
- Every model-supplied value passes through `hermes-text`, `hermes-word`, `hermes-slug` or
  `hermes-num`. These apply `default` → `toString` → `trunc` → `html`. The `html` escaper is the
  text/template builtin. sprout has no equivalent, and `escapeHTML` and `htmlEscape` are _not_
  defined. Without the escaper, a stray `<` in a PR title breaks the `format: html` rendering of
  Pushover.
- The template type-guards `stats` and `items` with `kindIs` before use. `dig` and field access both
  _error_ when a key holds the wrong type (for example `stats` as a string). A render error means
  that chaski drops the notification entirely, which is the exact case where you most want to hear
  from the job. The guards coerce a malformed value to an empty dict or list, so a degraded
  notification still arrives.
- The length is bounded per field, not globally, because truncating the composed body could cut a
  tag in half. The worst case (every field maxed, 12 items) renders at 861 chars, under the 1024
  limit of Pushover.
- `hermes-url` drops anything that does not start with `https://`, so a hallucinated `javascript:`
  or internal URL never reaches the action button of the notification.
- An unknown skill slug renders an `Unknown Skill` frame and does not error. A new skill that forgets
  to add its rows still notifies, visibly wrong and not silent.

### Changing a template

Validate offline before you commit. chaski checks snippet wiring at boot, so a typo in a
`{{ template }}` name takes the whole deployment down:

```bash
podman run --rm -v "$PWD:/c:z" ghcr.io/home-operations/chaski:latest \
  validate -c /c/chaski.yaml --payload /c/sample.json --route warning
```

`chaski.yaml` is `spec.values.config`, lifted out of the HelmRelease, with the apprise URL swapped
for `json://localhost/`. Render a sample for **all four** payload shapes. The dispatch is one shared
template, so a hermes edit can regress alertmanager.
