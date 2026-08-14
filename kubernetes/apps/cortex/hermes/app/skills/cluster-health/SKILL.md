---
name: cluster-health
description: "Hourly cluster health audit: cross-references alertmanager firing alerts with k8s state, attempts safe-class auto-fixes, and notifies via chaski. Designed for the hermes cron scheduler."
version: 1.0.0
author: Artemis
license: MIT
platforms: [linux]
metadata:
    hermes:
        tags: [Kubernetes, Monitoring, Alertmanager, Self-Healing, Operations]
        related_skills: []
---

# Cluster Health Audit

You are running on a schedule (every hour) to keep the Artemis cluster healthy. Goal: detect broken things early, fix what is safe to fix, and notify the operator only when human attention is genuinely required.

## Tools you have

- **k8s-mcp** (`/ops/mcp`) — full cluster query/exec API. Use these tools to inspect pods, deployments, nodes, events, logs.
- **curl / terminal** — for hitting alertmanager REST API directly.
- **chaski** (`http://chaski.observability.svc.cluster.local:8080`) — notification relay to Pushover. POST a JSON body of shape `{"title":"...","message":"...","url":"..."}` to `/hooks/info` (low priority) or `/hooks/warning` (normal priority) or `/hooks/critical` (urgent).

## Step 1 — Pull firing alerts

Query alertmanager's v2 API:

```bash
curl -s 'http://alertmanager.observability.svc.cluster.local:9093/api/v2/alerts?active=true&silenced=false&inhibited=false&unprocessed=true' \
  | python3 -m json.tool
```

Capture every alert's `labels.alertname`, `labels.severity`, `labels.namespace`, and `annotations.description`. If the array is empty, jump to Step 4 (idle summary).

## Step 2 — Cross-reference with cluster state

For each alert, use the k8s-mcp tools to confirm the alert's claims against live state. Examples:

- `KubePodCrashLooping` in namespace `cortex` → fetch the pod, check its `state.waiting.reason`, read recent container logs.
- `KubePodNotReady` → check pod's `status.conditions`, node pressure, recent events.
- `KubeDeploymentReplicasMismatch` → compare `spec.replicas` with `status.readyReplicas`; check pod template hash matches.

Discard any alert whose state has already self-corrected since alertmanager last evaluated.

## Step 3 — Auto-fix safe classes

You may attempt only these classes of remediation. Anything else → notify, do not touch.

| Class                                           | Action                                                                                                                             |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `CrashLoopBackOff` pod                          | `kubectl delete pod <name> -n <ns>` (forces a fresh restart from the Deployment's spec).                                           |
| Evicted pod                                     | `kubectl delete pod <name> -n <ns>` (cluster will reschedule on a healthy node).                                                   |
| Stuck terminating pod                           | `kubectl delete pod <name> -n <ns> --grace-period=0 --force` (only if `metadata.deletionTimestamp` exists and finalizer is stuck). |
| Deployment with 0/READY replicas but PDB allows | `kubectl scale deploy <name> -n <ns> --replicas=N` where N is the prior healthy count.                                             |

You may **not** touch:

- PersistentVolumeClaims / PersistentVolumes
- RBAC (Roles, RoleBindings, ClusterRoles, ServiceAccounts)
- Anything in `kube-system`, `flux-system`, `external-secrets`, `pocket-id`, or other CRD-bearing namespaces unless the alert explicitly says it is safe.
- Anything that would delete a workload which is not in `CrashLoopBackOff` or `Evicted`.

Before any mutation, run `kubectl auth can-i <verb> <resource> -n <ns>` to confirm the agent's own permissions. Refuse and notify if the action would require escalation.

After every mutation, re-query state in Step 2 to confirm the fix took effect (or didn't).

## Step 4 — Notify

Compose a single chaski message summarising what you found and what you did. Format:

```bash
CHASKI=http://chaski.observability.svc.cluster.local:8080
ROUTE=info   # use 'warning' if any auto-fix failed; 'critical' if cluster is degraded and nothing could be fixed

curl -s -X POST "$CHASKI/hooks/$ROUTE" \
  -H 'Content-Type: application/json' \
  -d @- <<JSON
{
  "title": "Cluster health audit",
  "message": "$(cat <<EOF
<b>Alerts fired:</b> N (M self-resolved)
<b>Auto-fixed:</b> K (list them)
<b>Needs human attention:</b> J (list them)
EOF
)",
  "url": "https://alertmanager.dcunha.io/alerts"
}
JSON
```

- If everything was quiet and no auto-fixes happened, still send a single `info` message saying so — keeps the silence observable.
- If something couldn't be auto-fixed, **also** send a per-issue `warning` message with one alert's details.

## Hard rules

- Never post to `/hooks/critical` — reserve that for outage-class situations only; this hourly job should rarely need it.
- Never mutate a resource you haven't first queried.
- Never trust an alert's `description` blindly — verify against live state before acting.
- If chaski itself is unreachable (timeout / 5xx), fall back to writing the summary to `/opt/data/.hermes/health-reports/$(date -I).md` so the operator can read it later.
