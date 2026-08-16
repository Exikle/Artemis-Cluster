# TargetDown triage (Artemis cluster)

Worked example: 2026-08-14, `TargetDown` for `job=smartctl-exporter`, "100% of the smartctl-exporter/ targets in namespace are down", active ~36h.

## Key insight: label grouping

Do NOT trust "100% of the targets are down". The TargetDown rule groups by
`(job, namespace, service)`. A **static** scrape target carries no `namespace`/`service`
labels, so it forms its own single-target group: 1/1 down = 100% for that group, while the
rest of the job scrapes fine. The empty namespace in the description is the tell.

## Diagnosis recipe

1. **Check the workload first** (cheap): is the Deployment/DaemonSet healthy?
    - `k8s_resources_list apps/v1 DaemonSet` (or Deployment) — 7/7 ready ⇒ NOT a pod problem.
    - Pod label gotcha: search by the chart's real label set, e.g. this chart uses
      `app.kubernetes.io/name=prometheus-smartctl-exporter` — searching `app=smartctl-exporter`
      returns nothing. The DaemonSet name also carried an `idx=i0` label (`smartctl-exporter-0`).

2. **Query scrape health from VictoriaMetrics** (single, port 8428):

    ```bash
    curl -s -G 'http://victoria-metrics-server.observability.svc.cluster.local:8428/api/v1/query' \
      --data-urlencode 'query=up{job="smartctl-exporter"}' -o /tmp/up.json -w '%{http_code}\n'
    ```
    - `up=1` targets carry `container`/`endpoint`/`namespace`/`service` labels → service-discovered.
    - `up=0` targets WITHOUT those labels → **static targets** — the usual culprit.

3. **Per-target scrape URL + last error** from vmagent (port 8429):
    ```bash
    curl -s -G 'http://vmagent-vmagent.observability.svc.cluster.local:8429/api/v1/targets' \
      --data-urlencode 'state=any' -o /tmp/targets.json -w '%{http_code}\n'
    ```
    For each `data.activeTargets[]` with `labels.job == <job>`: read `scrapeUrl`, `health`,
    `lastError`. The error text names the real cause (HTTP 500 body, connection refused, DNS…).

**Parsing `/api/v1/targets` without jq (jq is NOT installed in the cron env):** the
response embeds full `discoveredLabels` (k8s discovery metadata) per target and can be
**multi-MB — 8.5MB observed at 116 targets**. Never grep it with patterns that span a
discoveredLabels block (e.g. `grep -o '__address__":"[^"]*"'` alone) — that hung for
900s in the 2026-08-15 run. Instead:

- Narrow server-side: add `&scrapePool=<url-encoded-pool>` (e.g.
  `staticScrape%2Fobservability%2Fsmartctl-exporter-pantheon%2F0`) to return a tiny
  single-target payload.
- Or grep only short atomic substrings that never span blocks:
  `grep -o '"scrapeUrl":"[^"]*"' | sort | uniq -c`, `grep -o '"health":"[^"]*"' | sort | uniq -c`,
  `grep -o '"job":"[^"]*"' | sort | uniq -c`.
- The stale target's `__address__` lives inside discoveredLabels; extract it with a
  bounded-context grep (`grep -o '.\{0,60\}<pool-name>.\{0,120\}'`) only after the file
  has been narrowed, or skip it and rely on the `up` vector (which already carries
  `instance=`).
- VM `/api/v1/query` responses put values in `"value":[<unix-ts>,"1"]` — the literal
  `"up":1` never appears, so `grep -o '"up":[0-9.]*'` returns nothing. Grep
  `"__name__":"up"` and count trailing `"1"` values, or just read the file — a bare
  `up{job=...}` query is ~2KB and safe to read in full.

## What the smartctl case looked like

- 7 service-discovered targets (DaemonSet pods, `instance` = node hostname) — all `up=1`.
- 1 static target `http://10.10.99.104:9633/metrics` (`instance=pantheon`) — HTTP 500 with
  "44 error(s) occurred" while collecting (smartctl cannot read devices on that host).
- `10.10.99.104` matched **no current node** (nodes were .101–.103, .201–.204) ⇒ stale static
  target left over from a removed/replaced host; the responder on that IP is a leftover or
  unrelated host process.

## Classification

- Workload healthy + stale/broken static target = **NOT auto-fixable** (no
  CrashLoopBackOff/Evicted pod, no 0-replica deployment). Fix = scrape-config edit
  (Flux-managed observability) or host-side repair. Send a per-issue chaski `warning`, list
  under "Needs human attention".
- Never delete pods / scale anything for a TargetDown alert unless a pod-level class
  (CrashLoopBackOff / Evicted / stuck-terminating) is independently confirmed.

## Cluster topology note (2026-08-14, corrected 2026-08-14 ~20:35 EDT)

The cluster has **7 nodes, not 8**. Live `k8s_resources_list` (v1 Node) on the
~42.5h run verified: talos-cp-01/02/03 (.101–.103), talos-w-01/02 (.201/.202),
talos-gpu-01 (.203), ymir (.204) — exactly 7. The earlier "grew from 7 to 8
nodes when ymir joined" claim was a miscount (the names it listed count to 7);
the recurrence entries saying "all 8 nodes Ready" (the ~39h and ~41.5h runs)
were wrong, and the ~40h entry's "7 nodes" was correct, not a copy-paste
regression as previously annotated. Going forward: **expect 7 nodes**, and
always re-verify the count from live state rather than copying the previous
entry's topology line verbatim.

## Recurrence log

- 2026-08-14 (later run, alert active ~38h): identical diagnosis re-confirmed — 7/7
  DaemonSet pods up=1, single static target `10.10.99.104:9633` down (HTTP 500, 44
  collection errors), IP still matches no node. The fix (remove the stale static
  target from the Flux-managed scrape config, or repair the host on .104) had NOT
  landed between runs.
- 2026-08-14 (hourly run, alert active ~38.5h): re-confirmed identical via
  `targetdown-check.sh` — 7/7 DaemonSet pods up=1 (talos-cp-01/02/03, talos-gpu-01,
  talos-w-01/02, ymir), single static target `10.10.99.104:9633` down (HTTP 500, 44
  collection errors), `.104` still matches no current node (nodes are .101–.103,
  .201–.204). No pending pods; all 7 nodes Ready. Fix still NOT landed.
- 2026-08-14 (hourly run, alert active ~39h): re-confirmed identical via
  `targetdown-check.sh` — 7/7 DaemonSet pods up=1, single static target
  `10.10.99.104:9633` down (HTTP 500, 44 collection errors), `.104` still matches
  no current node. No pending pods; all 8 nodes Ready (ymir now 40h old, node top
  shows no pressure: max CPU 85% on talos-gpu-01, max mem 66% on talos-cp-01).
  Fix still NOT landed.
- 2026-08-14 (hourly run, alert active ~40h): re-confirmed identical via
  `targetdown-check.sh` — 7/7 DaemonSet pods up=1, single static target
  `10.10.99.104:9633` down (HTTP 500, 44 collection errors), `.104` still matches
  no current node. No pending pods; all 7 nodes Ready. Fix still NOT landed.
- 2026-08-14 (hourly run, alert active ~41.5h, 5th logged recurrence):
  re-confirmed identical via `targetdown-check.sh` — 7/7 DaemonSet pods up=1,
  single static target `10.10.99.104:9633` down (HTTP 500, 44 collection
  errors), `.104` still matches no current node (nodes are .101–.103, .201–.204).
  No pending pods; all 8 nodes Ready. Node top: talos-gpu-01 93% CPU (elevated,
  no pressure), max mem 66% on talos-cp-01. Fix still NOT landed.
- 2026-08-14 (hourly run, alert active ~42.5h, 6th logged recurrence):
  re-confirmed identical via `targetdown-check.sh` — 7/7 DaemonSet pods up=1
  (talos-cp-01/02/03, talos-gpu-01, talos-w-01/02, ymir), single static target
  `10.10.99.104:9633` down (HTTP 500, 44 collection errors), `.104` still
  matches no current node. No pending pods; 7 nodes Ready (talos-cp-01/02/03,
  talos-gpu-01, talos-w-01/02, ymir — no node pressure: max CPU 63% on
  talos-gpu-01, max mem 64% on talos-cp-01). Fix still NOT landed.
- 2026-08-14 (hourly run, alert active ~44h, 7th logged recurrence):
  re-confirmed identical via `targetdown-check.sh` — 7/7 DaemonSet pods up=1,
  single static target `10.10.99.104:9633` down (HTTP 500, 44 collection
  errors), `.104` still matches no current node (nodes are .101–.103, .201–.204).
  No pending pods; 7 nodes Ready. Node top: talos-gpu-01 96% CPU (elevated,
  no pressure; consistent with prior runs), max mem 65% on talos-cp-01.
  Fix still NOT landed.
- 2026-08-14 (hourly run, alert active ~46h, 9th logged recurrence):
  re-confirmed identical via `targetdown-check.sh` — 7/7 DaemonSet pods up=1
  (talos-cp-01/02/03, talos-gpu-01, talos-w-01/02, ymir), single static target
  `10.10.99.104:9633` down (HTTP 500, 44 collection errors), `.104` still
  matches no current node (nodes are .101–.103, .201–.204). No pending pods;
  7 nodes Ready. Node top: talos-gpu-01 55% CPU / 30% mem (consistent with
  8th entry's noted drop from 96% to ~51% — new baseline holds), max mem 65%
  on talos-cp-01 (consistent with prior entries, 64–66%). Fix still NOT
  landed.
- 2026-08-14 (hourly run, alert active ~45h, 8th logged recurrence):
  re-confirmed identical via `targetdown-check.sh` — 7/7 DaemonSet pods up=1
  (talos-cp-01/02/03, talos-gpu-01, talos-w-01/02, ymir), single static target
  `10.10.99.104:9633` down (HTTP 500, 44 collection errors), `.104` still
  matches no current node. No real pending pods (one short-lived init job
  `qbittorrent-20260815025100` warming up on talos-w-02, not stuck).
  7 nodes Ready. Node top: talos-cp-01 27% CPU / 66% mem (consistent with
  prior entries), talos-gpu-01 51% CPU / 29% mem (lower than prior peaks —
  **new deviation: CPU dropped from 96% to 51%**). Fix still NOT landed.

- 2026-08-15 (hourly run, alert active ~47h, 10th logged recurrence):
  re-confirmed identical via `targetdown-check.sh` — 7/7 DaemonSet pods up=1
  (talos-cp-01/02/03, talos-gpu-01, talos-w-01/02, ymir), single static target
  `10.10.99.104:9633` down (HTTP 500, 44 collection errors), `.104` still
  matches no current node (nodes are .101–.103, .201–.204). No pending pods;
  7 nodes Ready. Node top: talos-gpu-01 68% CPU / 30% mem (modest uptick from
  the 51–55% baseline in the 8th/9th entries, well below the 93–96% earlier
  peaks — consistent, no pressure), talos-cp-01 68% mem (slightly above the
  64–66% prior range, still no pressure). Fix still NOT landed.
- 2026-08-15 (hourly run, alert active ~52h, 11th logged recurrence):
  re-confirmed identical via `targetdown-check.sh` — 7/7 DaemonSet pods up=1
  (talos-cp-01/02/03, talos-gpu-01, talos-w-01/02, ymir), single static target
  `10.10.99.104:9633` down (HTTP 500, 44 collection errors), `.104` still
  matches no current node (nodes are .101–.103, .201–.204). No pending pods;
  7 nodes Ready. Node top: talos-gpu-01 58% CPU / 31% mem (consistent with the
  51–68% recent baseline, no pressure), max mem 64% on talos-cp-01 (consistent
  with 64–66% prior range), talos-w-02 55% CPU (elevated vs its usual ~27%,
  no pressure). Fix still NOT landed.
- 2026-08-15 (hourly run, **RESOLVED** — alert active ~52h+, 11 recurrences
  logged): TargetDown no longer firing (active set has only Watchdog). Live
  state confirms the fix landed: `up{job="smartctl-exporter"}` is 8/8 series
  = 1, including `instance="pantheon"` (the previously-stale static target);
  vmagent reports 116/116 targets health=up; static target
  `http://10.10.99.104:9633/metrics` now scrapes successfully (was HTTP 500,
  44 collection errors). No pending pods; 7 nodes Ready (talos-cp-01/02/03,
  talos-gpu-01, talos-w-01/02, ymir). Node top: max CPU 51% on talos-gpu-01
  (consistent with the 51–68% recent baseline), max mem 62% on talos-cp-02
  (consistent with 64–66% prior range) — no pressure anywhere. Scrape-config
  edit or host-side repair on .104 took effect.

When an alert documented here reappears with the same `alertname`+`job`, do not
re-derive the diagnosis: re-run `targetdown-check.sh <job>`, confirm the workload
is healthy, then notify with the "previously triaged — fix pending" framing and
restate the fix. Add a dated line to this log each time it recurs so the operator
can see how long the fix has been outstanding. When the alert clears, add a **RESOLVED**
entry in the same format (fresh node count + node-top, plus what changed — e.g. "static
target now scrapes up, was HTTP 500") so the outstanding-time story is closed and later
audits don't re-open a dead case. Each entry must re-verify the node
count and node-top values from live state (earlier entries miscounted 7 vs 8 by
copying the prior line; the count is 7 as of 2026-08-14) and annotate elevated
metrics as "consistent with prior entries" or "new deviation" — trend anchoring
is how later audits distinguish a known pattern from fresh trouble.

**Log ordering discipline:** append recurrence entries in strict chronological order
(newest active-hours figure last). The log currently has the ~46h/9th entry physically
before the ~45h/8th entry — an out-of-order append that muddles recurrence counting and
trend comparison. When adding an entry, confirm its `~Nh` figure is newer than the
previous entry's before appending; if the recurrence number and hours disagree with the
entry above, the log is out of order.
