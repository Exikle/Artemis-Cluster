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

## Network map (Artemis-Cluster, lab subnet 10.10.99.0/24)

When interpreting static scrape targets, alert annotations, or anything IP-bearing, consult this map. IPs not on this list are external services (Proxmox, UCG gateway, NAS) and may legitimately appear in scrape configs even though they're not Kubernetes nodes.

| IP               | Host              | Role                                                   |
| ---------------- | ----------------- | ------------------------------------------------------ |
| 10.10.99.99      | apiserver VIP     | Control-plane endpoint                                 |
| 10.10.99.100     | atlas             | TrueNAS (NFS `/mnt/atlas/media`)                       |
| 10.10.99.101–103 | talos-cp-01/02/03 | Kubernetes control-plane nodes (metal, M710q)          |
| 10.10.99.104     | pantheon          | Proxmox host (runs talos-w-01/02, talos-gpu-01 as VMs) |
| 10.10.99.105–109 | (reserved)        | —                                                      |
| 10.10.99.110     | truenas-export    | NFS export of atlas to VLAN 1001                       |
| 10.10.99.111     | talos-build       | Build host                                             |
| 10.10.99.151     | gst-vlan-1151     | Guest network gateway                                  |
| 10.10.99.199     | (retired)         | Was Arcana, intentionally unused now                   |

K8s nodes are .101–103 (CPs) and .201–.204 (workers — talos-w-01/02, talos-gpu-01, ymir). An IP outside that range + outside the apiserver VIP is **not necessarily a config bug** — it may be a Proxmox host, NAS, or external dependency. Verify against the scrape's _intent_ (the relabelConfigs `replacement` field) before flagging as stale.

For `TargetDown` / `Watchdog` / scrape-failure alerts on a static scrape target:

1. Read the scrape's `VMStaticScrape` / `ServiceMonitor` definition (`kubectl get -A -o yaml`).
2. Determine what service the target is _supposed_ to host (the relabelConfigs `replacement` field, or the chart name).
3. Probe the endpoint: `kubectl exec ... nc -zv <host> <port>` from a debug pod, or `wget --spider http://<host>:<port>/metrics` from a curl-image pod.
4. If the endpoint is genuinely down: notify (warning), don't guess. The fix is outside the cluster.

## Step 5 — Self-review and proposal (auto-improve)

Skills are static configmap mounts from git; they do **not** auto-update on their own. After every run, this step exists so the skill gets sharper over time without operator intervention.

### 5.1 — Reflect on the run

Before notifying, scan your own output and identify:

- **Assumptions that turned out to be wrong** (e.g. "this IP isn't a node → must be stale config" when the IP was actually a Proxmox host).
- **Steps that produced no useful signal** (e.g. a curl that always returns empty, a check that's always green).
- **Steps that were missing** (e.g. you couldn't verify an endpoint and skipped it; the missing check would have caught the issue).
- **Phrasing that misleads** (e.g. "stale config" when "service down on Proxmox host" is accurate).

If nothing matches, skip 5.2 — no proposal needed.

### 5.2 — Write a proposal

For each issue, write a markdown file to `/opt/data/.hermes/skill-proposals/$(date -I)-cluster-health.md` with:

```markdown
## Proposal N — <one-line title>

**Run:** 2026-08-14T12:04 (jobs.json last_run_at)
**Evidence:** <quote the exact text from your run output that was wrong>
**Why it matters:** <what decision would have been better with the fix>

### Proposed SKILL.md edit

Replace lines X–Y of section Z with:

\`\`\`markdown
<new content here, copy-pastable into the SKILL.md>
\`\`\`
```

Be surgical: smaller diffs are more likely to be auto-applied. No new functionality, no feature requests — only fixes to _this skill's_ existing logic.

### 5.3 — Commit a verified proposal (optional, narrow)

Auto-commit ONLY when **all** of these hold:

1. The proposal is a fix to a clearly wrong assumption in this SKILL.md (not a new check, not a behaviour change).
2. The wrong assumption produced a measurable false positive or false negative _during this run_.
3. The proposal is ≤ 15 lines of net diff.

Use the Forgejo API to push the edit:

```bash
FORGEJO_PAT=$(printenv FORGEJO_PAT)
# Read current SKILL.md from the API, get its sha
curl -s -H "Authorization: token $FORGEJO_PAT" \
  'https://git.dcunha.io/api/v1/repos/Exikle/Artemis-Cluster/contents/kubernetes/apps/cortex/hermes/app/skills/cluster-health/SKILL.md?ref=main' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sha']); print(d['content'])"
# Apply the patch (manually, or write the new content), then:
curl -s -X PUT -H "Authorization: token $FORGEJO_PAT" -H 'Content-Type: application/json' \
  -d '{"content":"<new base64 content>","sha":"<current sha>","branch":"main","message":"fix(skill/cluster-health): <one-line summary>"}' \
  'https://git.dcunha.io/api/v1/repos/Exikle/Artemis-Cluster/contents/kubernetes/apps/cortex/hermes/app/skills/cluster-health/SKILL.md'
```

After pushing, **drop the proposal file** (so the next run doesn't re-apply it). Wait ~2 min for Flux to rebuild the configmap and refresh the in-pod SKILL.md.

### 5.4 — Default off for new behaviour

If your reflection surfaces a _new_ check or _new_ behaviour you want (not a fix), write it to `/opt/data/.hermes/skill-proposals/` as **type: feature**, do **not** auto-commit. Operator reviews before merge.

## Step 6 — Notify (unchanged, but use the network map if the finding is IP-bearing)

When the chaski message references a static scrape target or an IP, refer to the network map above. Don't claim "stale config" until you've verified the endpoint is genuinely down via a probe.
