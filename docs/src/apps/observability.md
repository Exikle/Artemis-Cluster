# Observability

The observability stack lives in the `observability` namespace.

---

## Applications

| App                                | Purpose                           | URL                      |
| ---------------------------------- | --------------------------------- | ------------------------ |
| Prometheus (kube-prometheus-stack) | Metrics collection + Alertmanager | internal                 |
| Grafana (grafana-operator)         | Dashboards                        | internal                 |
| Victoria Logs                      | Log aggregation                   | internal                 |
| Fluent Bit                         | Log shipping to Victoria Logs     | —                        |
| Gatus                              | Uptime / endpoint monitoring      | https://status.dcunha.io |
| Kromgo                             | Prometheus badge endpoint         | https://kromgo.dcunha.io |
| Blackbox Exporter                  | HTTP/TCP probing for Gatus        | —                        |
| KEDA                               | Event-driven autoscaling          | —                        |
| UniFi Poller                       | UniFi metrics → Prometheus        | —                        |

---

## Prometheus (kube-prometheus-stack)

Full kube-prometheus-stack including:

- Prometheus server
- Alertmanager
- Node exporter
- kube-state-metrics

### Alertmanager

Alert routing is configured in `kubernetes/components/alerts/alertmanager/`. Active alerts are surfaced in the README badge.

If Prometheus WAL is corrupted after a node crash:

```bash
# Scale down
kubectl scale -n observability statefulset prometheus-kube-prometheus-stack-prometheus --replicas=0

# Wipe WAL only (compacted blocks are safe)
kubectl -n observability exec <prometheus-pod> -- rm -rf /prometheus/prometheus-db/wal/

# Scale up
kubectl scale -n observability statefulset prometheus-kube-prometheus-stack-prometheus --replicas=1
```

> Do NOT delete individual WAL segments — this creates a non-sequential gap and causes a startup failure.

---

## Grafana

Deployed via the `grafana-operator`. The operator manages a `Grafana` CR with:

- Datasources: Prometheus, Victoria Logs
- Dashboards: imported from app-specific `GrafanaDashboard` resources and JSON ConfigMaps

Apps that ship dashboards (Flux, Envoy Gateway, Cloudflare Tunnel, etc.) create `GrafanaDashboard` resources in their own namespaces, which the operator picks up automatically.

---

## Victoria Logs

Replaces Loki for log aggregation. Fluent Bit ships logs from all pods to Victoria Logs.

---

## Gatus

Endpoint monitoring with status badges. Endpoints are defined in `kubernetes/apps/observability/gatus/app/resources/cluster-endpoints.yaml`. Gatus also reads endpoint annotations from HTTPRoute resources (via `gatus.home-operations.com/endpoint` annotations on gateways).

**Groups:**

- `core` — Ping, Status Page, Heartbeat (Alertmanager watchdog)
- `external` — externally-accessible services (checked via `1.1.1.1` DNS)
- `internal` — LAN-only services

---

## Kromgo

Exposes Prometheus queries as shields.io-compatible badge endpoints for the README.

Current metrics:

| Metric                 | Query                                                         |
| ---------------------- | ------------------------------------------------------------- |
| `talos_version`        | `node_os_info{name="Talos"}`                                  |
| `kubernetes_version`   | `kubernetes_build_info`                                       |
| `flux_version`         | `flux_instance_info`                                          |
| `cluster_node_count`   | `count(kube_node_status_condition{condition="Ready"})`        |
| `cluster_pod_count`    | `sum(kube_pod_status_phase{phase="Running"})`                 |
| `cluster_cpu_usage`    | `avg(instance:node_cpu_utilisation:rate5m) * 100`             |
| `cluster_memory_usage` | Node memory utilisation %                                     |
| `cluster_age_days`     | `(time() - min(kube_node_created)) / 86400`                   |
| `cluster_uptime_days`  | Average node uptime                                           |
| `cluster_alert_count`  | `alertmanager_alerts{state="active"} - 1` (excludes Watchdog) |

The `cluster_power_usage` metric is defined but disabled — it requires a UPS SNMP exporter which is not running (Eaton UPS batteries are dead).

---

## UniFi Poller

Scrapes metrics from the UCG-Max (UniFi controller) and exposes them to Prometheus. Provides network device health, client counts, and traffic metrics in Grafana.
