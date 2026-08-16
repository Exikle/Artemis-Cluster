---
name: cluster-health
description: "Hourly cluster health audit: cross-references alertmanager firing alerts with k8s state, attempts safe-class auto-fixes, and notifies via chaski. Designed for the hermes cron scheduler."
version: 1.3.0
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
- **chaski** (`http://chaski.observability.svc.cluster.local:8080`) — notification relay to Pushover. POST the structured payload defined in Step 4 to `/hooks/info` (low priority), `/hooks/warning` (normal priority), or `/hooks/critical` (urgent). chaski renders the message; you never format it yourself.

## Step 1 — Pull firing alerts

Query alertmanager's v2 API — **never pipe curl into python3**: the security scanner flags pipes-to-interpreter as HIGH and marks the command `pending_approval`, which blocks unattended cron runs. Write to a file, then read/parse it in a separate step:

The same scanner also flags inline interpreter scripts (`python3 -c '...'` / `-e`); it may auto-approve in interactive sessions, but cron runs must not depend on that. For arithmetic such as alert age (needed in Step 2 for the pending-duration signal), use pure-bash `date` math instead of python:

```bash
age_h=$(( ($(date +%s) - $(date -d '2026-08-13T01:57:00-04:00' +%s)) / 3600 ))  # bash-only, scanner-safe
```

```bash
curl -s --max-time 20 -o /tmp/alerts.json -w '%{http_code}\n' \
  'http://alertmanager.observability.svc.cluster.local:9093/api/v2/alerts?active=true&silenced=false&inhibited=false&unprocessed=true'
# expect HTTP 200, then read_file /tmp/alerts.json and parse the JSON
```

Capture every alert's `labels.alertname`, `labels.severity`, `labels.namespace`, and `annotations.description`. If the array is empty, jump to Step 4 (idle summary).

Note: the `Watchdog` alert (severity `none`) is the always-on pipeline smoke test — it is _expected_ in every run; exclude it from the actionable count.

## Step 2 — Cross-reference with cluster state

For each alert, use the k8s-mcp tools to confirm the alert's claims against live state. Examples:

- `KubePodCrashLooping` in namespace `cortex` → fetch the pod, check its `state.waiting.reason`, read recent container logs.
- `KubePodNotReady` → check pod's `status.conditions`, node pressure, recent events.
- `KubeDeploymentReplicasMismatch` → compare `spec.replicas` with `status.readyReplicas`; check pod template hash matches.

Discard any alert whose state has already self-corrected since alertmanager last evaluated.

Always also sweep (independent of the alert list):

- **Pending pods** cluster-wide: `k8s_pods_list` with `fieldSelector=status.phase=Pending`. An empty result (`{"result": ""}` — empty _string_, not a JSON array) means zero pending pods: that is a clean sweep, not a failed query — do not re-run or treat it as an error.
- **Fresh batch-job pods are NOT stuck**: kopiur-scheduled jobs (labels `app.kubernetes.io/managed-by=kopiur`, `kopiur.home-operations.com/origin=scheduled`) legitimately appear in the Pending sweep as `Init:0/1` with age in **seconds** — that is normal job startup, not a stuck pod. Check the pod's `AGE` before flagging anything; only investigate pending pods that are minutes old or carry a waiting reason (ImagePullBackOff, CrashLoopBackOff, Unschedulable).
- **Node pressure**: all nodes Ready, no Memory/Disk/PID pressure. `kubectl` may be absent in the cron environment — use k8s-mcp instead: node Ready status from `k8s_resources_list` (v1 Node) + `k8s_nodes_top` CPU/mem as a pressure proxy.
- **Skill sync drift**: `read_file /opt/data/skills/.git-sync/drift.current`. A missing or empty file is the normal case. Any content means a skill was self-patched in place, so the init container **kept the live copy and parked the incoming git version** at that skill's `.git-incoming/SKILL.md` rather than overwriting. The pod and the repo are out of step until someone reconciles them: surface every line in `items` and set `status` to `attention`. Do not attempt the reconcile yourself — it needs a human diff.
- **k8s-mcp param quirk**: omit `labelSelector`/`fieldSelector`/`namespace` params when no filter applies — passing an empty string (e.g. `labelSelector=""`) fails schema validation (`'' does not match '^([/_.\-A-Za-z0-9=, ()!])+$'`) and aborts the sweep. Retry with the param omitted entirely.

For `TargetDown` alerts, run `scripts/targetdown-check.sh <job>` (or follow `references/targetdown-triage.md`): a static scrape target with no `namespace`/`service` labels forms its own label group, so "100% of the targets are down" can mean ONE stale target while the rest of the job is healthy. A workload-healthy TargetDown is **not** an auto-fixable class.

Scripts/references live under the skill install dir (`/opt/data/skills/operations/cluster-health/`); if the path drifts, locate with `find /opt/data/skills -name targetdown-check.sh`.

Before diagnosing from scratch, grep `references/` for a prior triage of the same `alertname`+`job`. If the case is documented (e.g. the smartctl-exporter stale static target in `targetdown-triage.md`), re-verify live state with the check script + workload health, then report it as **previously triaged — fix pending** and restate the known fix, rather than re-deriving the root cause. Recurring TargetDown with a healthy workload = stale static scrape target awaiting a Flux scrape-config edit, not a new incident.

When reporting a previously-triaged case, surface the **pending duration and recurrence count** front and center (e.g. summary: `TargetDown smartctl-exporter — previously triaged, fix pending ~40h, 12th recurrence`). Compute duration from `startsAt` → now; count recurrences in the reference log. A fix that survives many hourly audits is the one thing worth escalating — the outstanding-time signal is what lets the operator prioritize the Flux/host-side fix, not a re-stated diagnosis. Append the dated log line to `references/<triage>.md` (per its recurrence-log instruction) in the same run — include the live node count + node-top snapshot, annotate any elevated metric as **consistent with prior entries** (known pattern) or **new deviation** (escalate), and always re-verify the node count from live state rather than copying the previous entry's topology line verbatim.

**Resolution branch (previously-triaged alert absent from the active set):** do NOT treat it as a silent win or re-triage it — close the book. (1) Verify the underlying state from live sources, not the alert's absence alone (for TargetDown: `up{job="<job>"}` all series = 1 — including the formerly-stale static `instance` — plus vmagent target health). (2) Append a **RESOLVED** entry to the same `references/<triage>.md` log (same format: fresh node count + node-top, plus what changed, e.g. "static target now scrapes up (was HTTP 500)"), so the outstanding-time saga is closed and later runs don't re-open a dead case. (3) Surface the resolution in the `info` notification — it closes the operator's pending Flux/host-side fix task. The actionable alert count stays 0, but this run is NOT `[SILENT]` — a resolution report is the deliverable.

**Follow-up runs after a RESOLVED entry exists:** when the active set is quiet AND `references/<triage>.md` already carries a RESOLVED entry for the case, do NOT re-append a RESOLVED line or re-notify the resolution every hour — that duplicates the log and spams the operator. Instead: cheaply re-verify the underlying state still holds (one VM query, e.g. `up{job="<job>"}` all series = 1, including the formerly-stale static `instance`), then proceed as a normal quiet run — single chaski `info` message, and `[SILENT]` final response when the cron delivery instruction is in effect (the chaski info message is what keeps silence observable; the `[SILENT]` reply merely suppresses redundant delivery to the user). Only append to the log when state actually changes (new recurrence or a fresh resolution).

Concrete scanner-safe verification of "all series = 1" (no python — grep the saved VM response):

```bash
curl -s --max-time 20 -G 'http://victoria-metrics-server.observability.svc.cluster.local:8428/api/v1/query' \
  --data-urlencode 'query=up{job="<job>"}' -o /tmp/up.json -w '%{http_code}\n'
grep -o '"value":\[[0-9]*,"[0-9]"\]' /tmp/up.json | sort | uniq -c
# expect N occurrences of [ts,"1"] and ZERO of [ts,"0"] — including the formerly-stale static instance
```

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

**chaski owns the formatting, you supply data only.** Do not write HTML, markdown,
bullets, or a pre-formatted body — the `hermes-*` templates in chaski's config build
the notification. Any markup you put in a value is HTML-escaped and shown literally.

Send exactly one notification per run. **Do not build the JSON inline in the shell** — a heredoc or `-d '{...}'` is shell-escaping-heavy and trips the security scanner, which marks the command `pending_approval` and stalls unattended cron runs. Write the payload with `write_file`, then POST it with `--data @file`:

1. `write_file` the payload to `/opt/data/workspace/.health-reports/<name>.json` — **do not use `/tmp/`**: the `write_file` tool refuses `/tmp` paths (protected system path). (`curl -o /tmp/...` is fine — only the file tool is restricted.)

```json
{
    "skill": "cluster-health",
    "status": "ok",
    "summary": "3 alerts fired; 2 auto-fixed, 1 needs a human.",
    "stats": { "alerts": 3, "resolved": 1, "fixed": 2, "attention": 1 },
    "items": [
        "KubePodCrashLooping cortex/hermes — restarted, healthy",
        "TargetDown smartctl pantheon — probe failed, endpoint genuinely down"
    ],
    "url": "https://alertmanager.dcunha.io/alerts"
}
```

2. POST it (`ROUTE` per the routing table below):

```bash
curl -s --max-time 15 -X POST -H 'Content-Type: application/json' \
  --data @/opt/data/workspace/.health-reports/<name>.json \
  "http://chaski.observability.svc.cluster.local:8080/hooks/$ROUTE" \
  -o /tmp/chaski_resp.txt -w 'HTTP %{http_code}\n'
```

A 200 with an empty body means chaski accepted and relayed the message.

Field rules — every key required, exact names, exact types:

| Key       | Type   | Rule                                                                                 |
| --------- | ------ | ------------------------------------------------------------------------------------ |
| `skill`   | string | always the literal `cluster-health` — never a variation                              |
| `status`  | string | exactly one of `ok` \| `attention` \| `failed`; anything else renders `MALFORMED`    |
| `summary` | string | one plain-text sentence, no markup, truncated at 140 chars                           |
| `stats`   | object | integers only, keys exactly `alerts`, `resolved`, `fixed`, `attention` — 0, not null |
| `items`   | array  | plain strings, one line each; first 4 shown, the rest collapse to "…N more"          |
| `url`     | string | must start with `https://` or it is dropped                                          |

Status meaning: `ok` = nothing needs a human. `attention` = something is left for the
operator. `failed` = the audit itself could not complete.

Routing: `info` when `status` is `ok`, `warning` when `attention`, `critical` only when
`failed` **and** the cluster is degraded with nothing fixable.

- If everything was quiet, still send the `info` notification with zeroed stats — keeps the silence observable. On a quiet run, put the node sweep in `items` — e.g. `"N/N nodes Ready, no pressure (max CPU X% on <node>, max mem Y% on <node>)"` — plus one line for any re-verified resolved case, e.g. `"smartctl-exporter TargetDown remains fixed — up{job=...} 8/8 = 1 incl. static instance=pantheon"`. An elevated-but-not-actionable node metric belongs here too, so a trend is observable before it becomes an alert.
- Everything that needs a human goes in `items` of the single notification; do not send a second per-issue message.

## Hard rules

- Never post to `/hooks/critical` — reserve that for outage-class situations only; this hourly job should rarely need it.
- Never mutate a resource you haven't first queried.
- Never trust an alert's `description` blindly — verify against live state before acting.
- If chaski itself is unreachable (timeout / 5xx), fall back to writing the summary to `/opt/data/workspace/.health-reports/$(date -I).md` so the operator can read it later.

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

**Always commit a self-patch back to this repo — never only edit the in-pod copy.** The
repo is the source of truth; the in-pod file is an install of it. The init container will
not destroy an uncommitted local edit (it keeps the live copy and parks the incoming git
version at `.git-incoming/SKILL.md`), but until the change is committed the pod and the
repo stay diverged, every later git update to this skill is blocked from installing, and
the drift is reported as `attention` on every hourly run. Committing is what clears it.
Bump the `version:` in the frontmatter in the same edit.

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
