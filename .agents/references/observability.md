# Reference: Observability — Artemis-Cluster

## Grafana Operator

- `GrafanaDashboard` namespace = Grafana folder name — always deploy GrafanaDashboards in their **app's** namespace (e.g. `rook-ceph`, `volsync-system`), never in `default`
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
