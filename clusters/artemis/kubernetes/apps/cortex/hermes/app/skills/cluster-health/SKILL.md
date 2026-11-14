---
name: cluster-health
description: "Cluster health triage, woken by the cluster-health-check.sh pre-check only when it finds something new: verifies the findings against k8s state, attempts safe-class auto-fixes, and notifies via chaski. Designed for the hermes cron scheduler."
version: "4.0.0"
author: Artemis
license: MIT
platforms: [linux]
metadata:
    hermes:
        tags: [Kubernetes, Monitoring, Alertmanager, Self-Healing, Operations]
        related_skills: [skill-change-pr]
---

# Cluster Health Triage

The cron job runs `/opt/data/scripts/cluster-health-check.sh` every 30 minutes before you. The script already did the sweeps (firing alerts except Watchdog, nodes Ready or under pressure, pods Pending over 10 minutes, `up == 0` scrape targets including the static smartctl `pantheon` target) and wakes you only when the findings differ from the last wake, or when the same findings are 4 hours old. A clean cluster never reaches you. The script sends that `info` itself.

Your input is the Script Output block at the top of the prompt: a `findings:` list with one `- ` line per finding. Start from it. Do not redo the sweeps. If there is no such block (a manual run), run `bash /opt/data/scripts/cluster-health-check.sh` and use its output. If the output ends with `{"wakeAgent": false}`, there is nothing to triage, so reply `[SILENT]`.

Detect broken things, fix only the safe classes in Step 3, and send exactly one chaski notification. Alertmanager already pages in real time. This is a supplementary audit.

## Rules for every command (the security scanner stalls cron runs that break them)

- Never pipe into an interpreter (`curl … | python3`) and never run `python3 -c` / `-e`. Write with `curl -o <file>`, then `read_file` or `grep` the file in a separate step. `jq` is not installed.
- No heredocs and no inline JSON in the shell. Build JSON with `write_file`, then `curl --data @file`.
- `write_file` refuses `/tmp`. Author files only under `/opt/data/workspace/`. `curl -o /tmp/...` is fine.
- This skill's directory `/etc/hermes-skills/cluster-health/` is read-only. Never write there. Everything that you append to or rewrite lives in `/opt/data/workspace/cluster-health/` (called the state dir below) or `/opt/data/workspace/.health-reports/`.
- Arithmetic (alert age) in bash: `age_h=$(( ($(date +%s) - $(date -d '<startsAt>' +%s)) / 3600 ))`.
- Read the cluster with the k8s MCP tools. The approvals deny list blocks `kubectl delete`. Use the MCP tools for mutations (Step 3).
- MCP quirks: omit `labelSelector`, `fieldSelector`, and `namespace` when unused (an empty string fails validation). `k8s_resources_list` always needs both `apiVersion` and `kind`, for example `{"apiVersion": "v1", "kind": "Node"}`. The call is rejected without them.

Endpoints: alertmanager `http://alertmanager.observability.svc.cluster.local:9093`, VictoriaMetrics `http://victoria-metrics-server.observability.svc.cluster.local:8428`, chaski `http://chaski.observability.svc.cluster.local:8080`.

## Step 1: Read the findings

Each finding line is one of: `alert <name> severity=… ns=… target=… since <startsAt>`, `node … is not Ready`, `node … has <Pressure>`, `pod <ns>/<pod> Pending for over 10m`, `scrape target down: job=… instance=…`, or `check-failed: …`. Work through them in that order of importance.

- `check-failed: …` means the script could not reach alertmanager or VictoriaMetrics, so its sweep for that part did not run. Check the endpoint yourself with `curl` (endpoints above). If the endpoint answers now, run that sweep with the k8s tools. If it stays down, report status `failed`.

## Step 2: Verify against live state

For every finding, confirm its claim with the k8s tools (pod state, conditions, events, logs). Drop findings that already corrected themselves. Never trust an alert line alone.

- KubePodCrashLooping: `1/1 Running` is not proof of recovery. Keep the alert if `restartCount` is consistent with a loop since `startsAt`. Treat the alert as resolved only when `restartCount` stopped climbing for a full evaluation window and the last restart is older than 5 minutes.
- TargetDown or scrape target down: run `bash /etc/hermes-skills/cluster-health/scripts/targetdown-check.sh <job>`. The alert groups by (job, namespace, service). A static scrape target has no namespace/service labels, so "100% down" can mean one stale target while the rest of the job is healthy. A healthy workload with a down static target is not auto-fixable. The fix is a Flux scrape-config edit or a host repair. Detail: `/opt/data/workspace/cluster-health/targetdown-triage.md`.
- Pending pod: the script already ignores pods younger than 10 minutes. Investigate the waiting reason (ImagePullBackOff, Unschedulable, a PVC that will not bind).
- Node finding: read `k8s_nodes_top` and phrase CPU and memory readings with `/etc/hermes-skills/cluster-health/references/node-baselines.md`. Expect 7 nodes, and count them from the live result.

### Documented cases

Before diagnosing a finding from scratch, read `/opt/data/workspace/cluster-health/resolved-cases.md` (open and resolved tables) and `ls /opt/data/workspace/cluster-health/` for the same `alertname` + `job`/instance. Also check every row under Open cases against the findings. You can append to the files in the state dir. They are not part of the skill.

- Finding matches a documented case (open): re-verify it live, then report it as "previously triaged — fix pending" with the known fix, the pending duration in hours (`startsAt` to now) and the recurrence count (`grep -c '^- 20' /opt/data/workspace/cluster-health/<file>.md`). Example: `TargetDown smartctl-exporter — previously triaged, fix pending ~40h, 12th recurrence`. Append one log entry (format below). Add an Open cases row if none exists.
- Open-case row no longer in the findings: confirm the fix from live sources, not from the absence of the alert (for TargetDown: `up{job="<job>"}` all series = 1, including the formerly stale static instance). Append a RESOLVED log entry, move its row to the Resolved table in `resolved-cases.md` (state dir), and mention the resolution in the `info` notification. This run is not `[SILENT]`.
- Row in the Resolved table, no matching finding: run the verify query of the row once and put one line in `items` (for example `"smartctl-exporter TargetDown remains fixed — up{job=...} 8/8 = 1 incl. static instance=pantheon"`). Do not append to any log. The absence of the alert is not proof that the fix is durable. The query is.
- Not documented: diagnose the finding and handle it by Step 3 or notify. If it is a recurring alert that needs a human, `write_file` a short `<alert>-triage.md` in the state dir.

To check that all series = 1 without python, run:

```bash
curl -s --max-time 20 -G 'http://victoria-metrics-server.observability.svc.cluster.local:8428/api/v1/query' \
  --data-urlencode 'query=up{job="<job>"}' -o /tmp/up.json -w '%{http_code}\n'
grep -o '"value":\[[0-9]*,"[0-9]"\]' /tmp/up.json | sort | uniq -c
```

Expect N lines of `[ts,"1"]` and none of `[ts,"0"]`.

Log entry format (append to the file of the case in the state dir with terminal `echo '<entry>' >> <file>`, in strict chronological order, at most 3 lines): `- <YYYY-MM-DD HH:MMZ> <recurrence #N | RESOLVED>: <alert/instance>, active <N>h; <one line of live evidence>; <N>/<N> nodes Ready.` Append only when the state changes (new recurrence, fresh resolution, or a different sub-condition). A quiet run appends nothing. Keep the newest 10 entries per file. When a file has more, run `bash /etc/hermes-skills/cluster-health/scripts/trim-triage-log.sh <file> 10 /opt/data/workspace/cluster-health/archive` then `mv <file>.new <file>`.

### Sibling runs and divergence

If `write_file` warns `was modified by sibling subagent`, another run wrote the same report. Use `read_file` on the JSON of the sibling and compare:

- `status`, `stats` and `items` all identical: skip your POST and reply `[SILENT]`.
- Your live reading differs (a node metric moved to another band in `node-baselines.md`, a pending pod got scheduled, the `up{}` series count differs, or you re-verified a case that the sibling did not): POST your own message with the current accurate reading. Never say a reading is "back in" a band when its number is outside that band.

## Step 3: Auto-fix safe classes only

| Class                                                                     | Action                                                                                           |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `CrashLoopBackOff` pod                                                    | delete the pod with the k8s MCP pod-delete tool (`k8s_pods_delete`); its controller recreates it |
| Evicted pod                                                               | delete the pod, same tool                                                                        |
| Stuck terminating pod (`metadata.deletionTimestamp` set, finalizer stuck) | delete once. If it is still stuck, notify                                                        |
| Deployment at 0 ready replicas where the PDB allows                       | scale to the prior healthy count with the k8s MCP scale tool                                     |

Never touch: PVCs and PVs; RBAC (Roles, RoleBindings, ClusterRoles, ServiceAccounts); anything in `kube-system`, `flux-system`, `external-secrets`, `security`, or the operator namespaces (`cert-manager`, `cnpg-system`, `dragonfly-system`, `miroir-system`, `kopiur-system`, `system-upgrade`, `network`, `database`) unless the alert explicitly says it is safe; any workload that is not in `CrashLoopBackOff` or `Evicted`. Never delete a pod for a `TargetDown` unless a pod-level class is independently confirmed.

Query a resource before mutating it. If a mutation is refused, notify and stop. Do not look for another route. After every mutation, re-query to confirm the fix took effect.

## Step 4: Notify (one message per run)

chaski owns formatting. Supply data only: no HTML, no markdown, no bullets (markup is escaped and shown literally).

1. Get the timestamp: `date -u +%Y%m%dT%H%MZ`.
2. `write_file` `/opt/data/workspace/.health-reports/cluster-health-<timestamp>.json`:

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

3. POST it (`ROUTE` is `info`, `warning` or `critical`):

```bash
curl -s --max-time 15 -X POST -H 'Content-Type: application/json' \
  --data @/opt/data/workspace/.health-reports/cluster-health-<timestamp>.json \
  "http://chaski.observability.svc.cluster.local:8080/hooks/$ROUTE" \
  -o /tmp/chaski_resp.txt -w 'HTTP %{http_code}\n'
```

HTTP 200 with an empty body means chaski relayed it. On a timeout, 5xx or any non-200 response, write the same summary to `/opt/data/workspace/.health-reports/$(date -I).md` instead.

| Key       | Type   | Rule                                                                                  |
| --------- | ------ | ------------------------------------------------------------------------------------- |
| `skill`   | string | the literal `cluster-health`                                                          |
| `status`  | string | exactly `ok`, `attention` or `failed`; anything else renders `MALFORMED`              |
| `summary` | string | one plain-text sentence, at most 140 chars                                            |
| `stats`   | object | integers only, keys exactly `alerts`, `resolved`, `fixed`, `attention`; 0, never null |
| `items`   | array  | plain one-line strings; only the first 4 render, the rest collapse to "…N more"       |
| `url`     | string | must start with `https://` or it is dropped                                           |

Status: `ok` means nothing needs a human. `attention` means something is left for the operator. `failed` means the audit itself could not complete.

Route: use `info` for `ok`, `warning` for `attention`, and `critical` only for `failed` with a degraded cluster and nothing fixable.

`items` rules:

- Order by importance: unfixable alerts needing a human, failed auto-fixes, successful auto-fixes, then routine sweep lines. A fix is already counted in `stats.fixed`, so it must not push a live problem out of the first 4.
- If every finding corrected itself, still send `info` with zeroed stats and `"N/N nodes Ready, no pressure"` in `items`, plus one line per re-verified resolved case. Annotate an elevated but non-actionable reading against `node-baselines.md`.

## Final response

- Reply exactly `[SILENT]` and nothing else when nothing is new for the operator: status `ok`, no resolution, no auto-fix, no divergence, or a redundant sibling run. The chaski `info` keeps the run observable. `[SILENT]` only suppresses a duplicate delivery.
- Otherwise reply with a short plain report: `attention` items, auto-fixes, a RESOLVED case, or a band change. Never combine `[SILENT]` with other text.

## Hard rules

- Never mutate a resource you have not queried first.
- Do not edit this skill, because it is read-only. To propose a change, follow skill `skill-change-pr`.
- Check alerts against live state before you act on them.

## Network map (lab subnet 10.10.99.0/24)

| IP               | Host                                                                |
| ---------------- | ------------------------------------------------------------------- |
| 10.10.99.99      | apiserver VIP                                                       |
| 10.10.99.100     | atlas, TrueNAS (NFS `/mnt/atlas/media`)                             |
| 10.10.99.101-103 | talos-cp-01/02/03 (metal control plane)                             |
| 10.10.99.104     | pantheon, Proxmox host (runs talos-w-01/02 and talos-gpu-01 as VMs) |
| 10.10.99.201-204 | talos-w-01, talos-w-02, talos-gpu-01, ymir                          |

An IP outside this table is not automatically a stale config, because it can be an external host. For a static scrape target, read its `scrapeUrl` and `lastError` from vmagent (`targetdown-check.sh` prints them), then probe it once with `curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' http://<host>:<port>/metrics`, Call it stale only after the probe fails. If the endpoint is genuinely down, send a `warning`. The fix is outside the cluster.
