# Scheduling & Descheduler — home-infra

This file explains why pods land where they do. It also covers the two traps that cost a session on 2026-09-01 (Forgejo issue #1927).

## The scheduler packs on requests; watch requests, not `kubectl top`

kube-scheduler admits a pod only if the node has unreserved **requests** left. Actual usage does not affect admission. A node can sit at 43% measured CPU and still refuse every new pod because it is at 91% requested. This is how `talos-gpu-01` once stalled CI pods while it looked idle in `kubectl top`.

If a pod will not schedule, compare requests against allocatable. Do not use the metrics.

```bash
kubectl describe node <node> | sed -n '/Allocated resources/,/Events/p'
```

Do not "right-size" a request from a `kubectl top` snapshot. Bursty workloads idle near zero between bursts, so a point sample looks like waste. Measure p95 over a week instead:

```promql
quantile_over_time(0.95, sum by (pod) (rate(container_cpu_usage_seconds_total{pod=~"<app>-[0-9a-f]{6,}-.*"}[5m]))[7d:10m])
```

The p95 measurement showed that jellyfin and eco, both requesting 1000m, exceed a full core (jellyfin peaks near 11 cores during transcodes). They are under-requested, not over-requested. If you cut requests to unblock CI, you starve workloads that were sized honestly.

The pod-name regex matters. kopiur backup Jobs are named `<app>-<timestamp>-<suffix>`. They swamp the result set if you match on `<app>.*`.

## `LowNodeUtilization` needs an underutilized node or it silently does nothing

The plugin evicts from an overutilized node only when an underutilized node can receive the pods. If no node clears the low threshold, the plugin logs

```
"No node is underutilized, nothing to do here, you might tune your thresholds further"
```

and exits, even when nodes are over target. This repo ran in that dead state for months on absolute thresholds of 20/50. Every node was above 20% memory, so the underutilized set was always empty.

The plugin now runs `useDeviationThresholds: true`. The thresholds float around the cluster mean (±10% under, ±15% over) and are not absolute. On a small homogeneous cluster, the plugin stays quiet when the spread is even. It acts when one node drifts out, which is the only case worth evicting for. `evictionLimits.node: 5` caps the blast radius of any single pass.

The plugin is also deliberately **request-based**. `metricsUtilization` was removed. Balancing on measured usage cannot see the request packing that blocks scheduling, and this plugin exists to prevent that failure here.

## `kubectl cordon` is not a light-touch operation by default

Cordon adds `node.kubernetes.io/unschedulable:NoSchedule`. `RemovePodsViolatingNodeTaints` treats that taint like any other taint. It evicts everything that does not tolerate it. On 2026-09-02 it evicted **26 pods in one pass**, including the CNPG primary, and that forced a Postgres failover. Nothing was lost (CNPG `instances: 2` did its job and `postgres-rw` consumers never noticed). But a "cordon" that causes a mass restart is a real footgun.

The plugin now carries `excludedTaints: [node.kubernetes.io/unschedulable]`. This restores the documented cordon behavior: it stops scheduling _new_ pods and leaves running pods alone. Real taints are still enforced. `kubectl drain` is unaffected and remains the way to empty a node.
