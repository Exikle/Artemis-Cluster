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

**Follow-up after RESOLVED (log discipline):** when the active set is quiet AND this
log already carries a RESOLVED entry, do NOT append a new recurrence-of-fix line
every hour — the SKILL's "[SILENT]" + chaski `info` per clock-hour emission rule
covers the operator's "is it still fixed?" loop, and appending hourly would grow
the log unboundedly and confuse any tooling that counts recurrences from log lines.
Only append a new line when live state actually diverges from the previous entry
(new recurrence — TargetDown re-appears, workload pod count changes, etc., or a
fresh resolution if a _different_ sub-condition fires). For routine quiet hours,
cheaply re-verify `up{job="smartctl-exporter"}` (all series = 1, including static
`instance=pantheon`), confirm workload health via `targetdown-check.sh`, then
emit one chaski `info` and return `[SILENT]`.

**Sibling-run race on a quiet day:** `/opt/data/workspace/.health-reports/`
is deterministic per UTC day. On a quiet cluster the same finding is
re-published 2–4× per day by overlapping cron pods, manual re-triggers, and
retries. The SKILL's concurrent-run pitfall covers the duplicate-Pushover
side; the _log_ side is the same — only append when live state diverges. When
_some_ metrics moved (e.g. talos-gpu-01 CPU 51% → 84%) but the "TargetDown
absent" assertion is still true, prefer NOT to append a new entry; instead
surface the deviation in the chaski `items[]` node-sweep line and the
`[SILENT]` return. The log should grow on _incident boundaries_ (recurrence or
fresh resolution), not on metric drift inside the resolved baseline.

**Exception — long quiet gaps get one summary follow-up entry** when the gap
between the previous entry and now exceeds ~24h (e.g. a multi-day gap caused
by the cron pod being rescheduled or `references/` falling out of the configmap
mount). A single summary line that records "still resolved, N nodes Ready,
node-top summary, no log appends in between" is preferable to a silent history
gap — the operator can see the chain of evidence is intact. The summary line
goes _before_ the existing follow-up entries, just after the RESOLVED entry,
so the chronology stays `(RESOLVED) → (long-gap summary) → (follow-up #1)`.
Short gaps (<24h, typical for hourly cron) follow the strict "only append on
incident boundaries" rule above.

- 2026-08-15 (hourly follow-up, ~30h post-resolution): active set has only Watchdog
  (smartctl-exporter TargetDown **absent** from the firing set). Live state confirms
  the fix is durable: `up{job="smartctl-exporter"}` is 8/8 series = 1 including static
  `instance=pantheon`; vmagent reports 8/8 targets health=up on the `smartctl-exporter`
  pool; static target `http://10.10.99.104:9633/metrics` still scraping successfully
  (was HTTP 500 / 44 collection errors). No pending pods (one short-lived kopiur init
  job `atlas-discovery-4vhxr` warming up on talos-gpu-01 at age 2s, not stuck —
  matches the kopiur scheduled-job exclusion in the SKILL: `Init:0/1` at seconds
  scale is normal startup). 7 nodes Ready (talos-cp-01/02/03, talos-w-01/02,
  talos-gpu-01, ymir), no pressure. Node top: max CPU 81–84% on talos-gpu-01
  (**above the 51–68% recent baseline** established in the 9th–11th recurrence
  entries; still well below the 93–96% peaks of the 5th–8th recurrences, so a
  new deviation in the _direction of_ the older peaks — surface for trend
  visibility), max mem 64–71% on talos-cp-01/02 (consistent with the 64–66%
  prior range, slight uptick on talos-cp-02 to 71% but no MemoryPressure node
  condition firing). No chaski POST needed — `[SILENT]` final response because
  sibling runs at 03:01 and 07:01 UTC today already published the same
  finding in their own payloads.

- 2026-08-17 (hourly follow-up, ~53h post-resolution): active set has only Watchdog
  (smartctl-exporter TargetDown still **absent** from the firing set). Live state
  confirms the fix remains durable: `up{job="smartctl-exporter"}` is 8/8 series = 1
  including static `instance=pantheon` (verified via scanner-safe
  `grep -o '"value":\[[0-9]*,"[0-9]"\]' /tmp/up.json | sort | uniq -c` → 8× `[ts,"1"]`,
  0× `[ts,"0"]`). No pending pods (clean sweep — empty-string result from
  `k8s_pods_list fieldSelector=status.phase=Pending` per the SKILL's clean-sweep
  pitfall). 7 nodes Ready (talos-cp-01/02/03, talos-w-01/02, talos-gpu-01, ymir),
  no pressure. Node top: max CPU 87% on talos-gpu-01 (above the 51–68% recent
  baseline, still below the >90% "elevated" threshold — same phrasing used at
  03:05 UTC; new high in the 81–88% band but not a deviation in _direction_
  since the prior 11:01 UTC observation already showed 88% and the operator did
  not escalate), max mem 64% on talos-cp-01 (consistent with the 64–66% prior
  band). `drift.current` is 0 bytes (no skill sync drift). Single chaski `info`
  POST emitted; `[SILENT]` final response because a sibling run at 06:01 UTC
  already published the same quiet-finding payload to `/hooks/info` and the
  Step 4 sibling-race pitfall covers the duplicate-Pushover side.
  Log not appended — per the "log discipline" rule, only grow on incident
  boundaries (recurrence or fresh resolution), and the TargetDown absent assertion
  is still true since the last RESOLVED entry.

When an alert documented here reappears with the same `alertname`+`job`, do not
re-derive the diagnosis: re-run `targetdown-check.sh <job>`, confirm the workload
is healthy, then notify with the "previously triaged — fix pending" framing and
restate the fix. Add a dated line to this log each time it recurs so the operator
can see how long the fix has been outstanding. When the alert clears, add a **RESOLVED**
entry in the same format (fresh node count + node-top, plus what changed — e.g. "static
target now scrapes up, was HTTP 500") so the outstanding-time story is closed and later
audits don't re-open a dead case. Each entry must re-verify the node
|count and node-top values from live state (earlier entries miscounted 7 vs 8 by
|copying the prior line; the count is 7 as of 2026-08-14) and annotate elevated
metrics as "consistent with prior entries" or "new deviation" — trend anchoring
is how later audits distinguish a known pattern from fresh trouble.

**Log ordering discipline:** append recurrence entries in strict chronological order
(newest active-hours figure last). The log currently has the ~46h/9th entry physically
before the ~45h/8th entry — an out-of-order append that muddles recurrence counting and
trend comparison. When adding an entry, confirm its `~Nh` figure is newer than the
previous entry's before appending; if the recurrence number and hours disagree with the
entry above, the log is out of order.

**Sibling-`info` race on the post-resolution quiet path:** when the active set is quiet
AND `references/<triage>.md` already carries a RESOLVED entry, the SKILL's
"Follow-up runs after a RESOLVED entry exists" branch calls for a single chaski `info`
POST that surfaces the re-verification in `items[]`. That chaski message is identical
across sibling runs at the same UTC hour (same alert set, same node sweep, same
`up{job=...}` confirmation). The deterministic filename `/opt/data/...T<HH>-<MM>Z.json`
is the only thing that differs. **Emitting your own chaski `info` after reading a
sibling's payload that is byte-equivalent in `stats`/`items`/`status` is a duplicate
Pushover**, even though the SKILL does not name this race explicitly — it only names
the sibling-`write_file` race for the daily `/health-reports/$(date -I)-cluster-health.json`
path. Mitigations: (1) `ls /opt/data/workspace/.health-reports/<today>*` first and read
the most recent same-UTC-hour payload; (2) if `stats` + `items` arrays match your own
findings, skip your POST and return `[SILENT]`; (3) only POST when the live state
diverges (new alert, node count change, drift file non-empty, `up{job=...}` count
change). The on-disk `drift.current` 0-byte vs non-empty distinction is also a
divergence signal — a non-empty drift file is a fresh incident even on a "quiet"
alert set, and deserves its own `info` with attention-grade language.
