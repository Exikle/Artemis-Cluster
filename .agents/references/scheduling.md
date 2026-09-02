# Scheduling & Descheduler — Artemis-Cluster

Why pods land where they do, and the two traps that cost a session on 2026-09-01
(Forgejo issue #1927).

## The scheduler packs on requests; watch requests, not `kubectl top`

kube-scheduler admits a pod only if the node has unreserved **requests** left. Actual usage is
irrelevant to admission. A node can sit at 43% measured CPU and still refuse every new pod
because it is at 91% requested — which is exactly how `talos-gpu-01` stalled Tekton while
looking idle in `kubectl top`.

When a pod will not schedule, compare requests against allocatable, not the metrics:

```bash
kubectl describe node <node> | sed -n '/Allocated resources/,/Events/p'
```

**Do not "right-size" a request from a `kubectl top` snapshot.** Bursty workloads idle near zero
between bursts, so a point sample reads as waste. Measure p95 over a week instead:

```promql
quantile_over_time(0.95, sum by (pod) (rate(container_cpu_usage_seconds_total{pod=~"<app>-[0-9a-f]{6,}-.*"}[5m]))[7d:10m])
```

Measured 2026-09-02, and the reason #1927's "requests are inflated guesses" premise was wrong:
jellyfin (1000m request) and eco (1000m) both exceed a full core at p95 — jellyfin peaks near 11
cores during transcodes. They are under-requested, not over. frigate and the CNPG postgres pods
are correctly sized. Cutting the first two would have unblocked Tekton by starving the workloads
that were sized honestly.

The pod-name regex matters: kopiur backup Jobs are named `<app>-<timestamp>-<suffix>` and will
swamp the result set if you match on `<app>.*`.

## `LowNodeUtilization` needs an underutilized node or it silently does nothing

The plugin only evicts from an overutilized node when there is an underutilized node to receive
the pods. If nothing clears the low threshold, it logs

```
"No node is underutilized, nothing to do here, you might tune your thresholds further"
```

and exits — even with nodes over target. This repo ran in that dead state for months on absolute
thresholds of 20/50: every node was above 20% memory, so the underutilized set was always empty.

It now runs `useDeviationThresholds: true`, so the thresholds float around the cluster mean
(±10% under, ±15% over) rather than being absolute. On a small homogeneous cluster that keeps the
plugin quiet when the spread is even and lets it act when one node drifts out — which is the only
case worth evicting for. `evictionLimits.node: 5` caps the blast radius of any single pass.

It is also deliberately **request-based**: `metricsUtilization` was removed. Balancing on measured
usage cannot see the request packing that actually blocks scheduling, which is the failure this
plugin exists to prevent here.

## `kubectl cordon` is not a light-touch operation by default

Cordon adds `node.kubernetes.io/unschedulable:NoSchedule`. `RemovePodsViolatingNodeTaints` treats
that like any other taint and evicts everything that does not tolerate it — **26 pods in one pass**
on 2026-09-02, including the CNPG primary, forcing a Postgres failover. Nothing was lost (CNPG
`instances: 2` did its job and `postgres-rw` consumers never noticed), but "cordon" implying a
mass restart is a genuine footgun.

The plugin now carries `excludedTaints: [node.kubernetes.io/unschedulable]`, restoring the
documented cordon behaviour — stop scheduling _new_ pods, leave running ones alone — while real
taints are still enforced. `kubectl drain` is unaffected and remains the way to actually empty a
node.

## Tekton pipelines pin to one node

`coschedule: workspaces` (the Tekton default) starts an affinity assistant per PipelineRun and
pins every pod in the run to the node holding the run's RWO workspace PVC. If that node cannot
fit the run, the run cannot schedule _and cannot move_, and the failure reads misleadingly:

```
0/7 nodes are available: 1 Insufficient cpu, 6 node(s) didn't match pod affinity rules.
```

The 6 "didn't match" nodes are the assistant excluding them, not a real affinity problem — so
read that message as "one node is full", not "affinity is misconfigured".

`TektonConfig.spec.pipeline.default-affinity-assistant-pod-template` steers where the assistant —
and therefore the whole run — is allowed to land. It keeps workspaces off the contended GPU node.
Two OR'd `nodeSelectorTerms` are required, not one: node affinity `NotIn` does not match nodes
that lack the label at all, so a bare `gpu-tier NotIn [arc]` would silently exclude `talos-w-01`
and `talos-w-02` (which carry no `gpu-tier` label) — the two largest workers.

The ConfigMap the operator writes this into is **`tekton-system/config-defaults`**, following
`spec.targetNamespace`. There is an empty, unused `tekton-pipelines/config-defaults` left over
from an earlier layout; checking that one will tell you the setting did not apply when it did.
