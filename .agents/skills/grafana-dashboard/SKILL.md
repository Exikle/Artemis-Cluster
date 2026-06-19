# Skill: Grafana Dashboard

Create and manage Grafana resources via the Grafana Operator (CRD-based, not ConfigMaps or HelmRelease values).

> Also read `.agents/references/observability.md` before working on dashboards.

## All Resources Use `grafana.integreatly.org/v1beta1`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard # or GrafanaDataSource, GrafanaFolder, GrafanaAlertRuleGroup
```

## Instance Selector (required on every resource)

```yaml
spec:
    instanceSelector:
        matchLabels:
            dashboards: grafana
```

Verify the exact label by running:

```bash
kubectl get grafana -n observability -o yaml | grep -A5 "labelSelector\|dashboards"
```

## Namespace = Folder

The namespace a `GrafanaDashboard` is deployed in determines which Grafana folder it appears in. Deploy dashboards in the **app's own namespace**, not `observability` or `default`.

```yaml
metadata:
    name: rook-ceph-overview
    namespace: rook-ceph # → appears in "rook-ceph" folder in Grafana
```

## Datasource Names

Use these exact names (mismatch = silent empty panels):

| Name            | Type                               |
| --------------- | ---------------------------------- |
| `prometheus`    | Prometheus (kube-prometheus-stack) |
| `alertmanager`  | Alertmanager                       |
| `victoria-logs` | VictoriaLogs                       |

## CRITICAL: Escape All Grafana Variables

Every `$` in dashboard JSON **must** be doubled to `$$`. A single `$` is treated as a Go template variable and silently replaced with empty string.

```json
{ "expr": "rate(http_requests_total{job=$$job}[$$__rate_interval])" }
```

Common tokens to double:

- `$$__rate_interval`, `$$__range`, `$$__interval`
- `$$job`, `$$namespace`, `$$pod`, `$$node`
- `$$__from`, `$$__to`

## GrafanaDashboard Template

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
    name: <app>-overview
    namespace: <app-namespace>
spec:
    instanceSelector:
        matchLabels:
            dashboards: grafana
    json: |
        {
          "title": "<App> Overview",
          "uid": "<app>-overview",
          "panels": [...]
        }
```

## GrafanaDataSource Template

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDataSource
metadata:
    name: <name>
    namespace: <namespace>
spec:
    instanceSelector:
        matchLabels:
            dashboards: grafana
    datasource:
        name: <name>
        type: prometheus
        url: http://<service>.<namespace>.svc.cluster.local:<port>
        editable: true
        isDefault: false
```

`editable: true` is required — the Grafana Operator sets datasources read-only by default.

## Suppressing Bundled Chart Dashboards

Some charts unconditionally include GrafanaDashboards. Suppress via postRenderer:

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

## Common Issues

| Symptom                                  | Cause                               | Fix                                                            |
| ---------------------------------------- | ----------------------------------- | -------------------------------------------------------------- |
| Dashboard exists but panels show no data | Single `$` instead of `$$` in query | Double all `$` tokens                                          |
| Dashboard in wrong folder                | Deployed in wrong namespace         | Move to correct namespace; delete stale copy in old namespace  |
| Dashboard not appearing in Grafana       | Wrong `instanceSelector` label      | Check `kubectl get grafana -n observability` for correct label |
| Datasource fields all empty              | `editable: true` missing            | Add `editable: true` to datasource spec                        |
| Old dashboard overriding new             | Stale copy in `default` namespace   | `kubectl delete grafanadashboard <name> -n default`            |
