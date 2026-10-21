# TargetDown triage

## Key insight: label grouping

Do not trust "100% of the targets are down". The rule groups by `(job, namespace, service)`. A static scrape target has no `namespace`/`service` labels, so it forms its own one-target group (1/1 down = 100%) while the rest of the job scrapes fine. An empty namespace in the description is the tell.

## Diagnosis recipe

1. Workload first: is the DaemonSet/Deployment fully ready (for smartctl-exporter, 7/7)? If yes, it is not a pod problem. Pod labels follow the chart (`app.kubernetes.io/name=prometheus-smartctl-exporter`), so a guessed `app=<job>` selector returns nothing.
2. Run `bash /etc/hermes-skills/cluster-health/scripts/targetdown-check.sh <job>`. It prints `up{job=...}` per instance and each vmagent target's `scrapeUrl`, `health` and `lastError`. `up=1` series carry `container`/`endpoint`/`namespace`/`service` (service-discovered); `up=0` series without them are static targets, the usual culprit. `lastError` names the real cause (HTTP 500 body, connection refused, DNS, size limit).
3. Parsing without jq: `/api/v1/targets` is multi-MB because each target embeds `discoveredLabels` (8.5 MB at 116 targets). Never `grep -o` a pattern that can span a `discoveredLabels` block; one such grep hung for 900 s. Narrow server-side with `&scrapePool=<url-encoded pool>` (e.g. `staticScrape%2Fobservability%2Fsmartctl-exporter-pantheon%2F0`), or grep short atomic fields only (`"scrapeUrl":"[^"]*"`, `"health":"[^"]*"`, `"job":"[^"]*"`). VM query values look like `"value":[<ts>,"1"]`; the literal `"up":1` never appears.

## Classification

Healthy workload plus a down static target is not auto-fixable. The fix is a Flux scrape-config edit (observability) or a host-side repair. Send a `warning` under "needs human attention". Never delete pods or scale anything for a TargetDown unless a pod-level class (CrashLoopBackOff, Evicted, stuck terminating) is independently confirmed.

## Cases

### smartctl-exporter, static `instance=pantheon` (RESOLVED 2026-08-15)

Static target `http://10.10.99.104:9633/metrics` (the Proxmox host `pantheon`, not a Kubernetes node) returned HTTP 500 with "44 error(s)" while smartctl could not read devices on the host. 7 service-discovered DaemonSet targets were up the whole time. Open ~52 h, 11 logged recurrences. Fixed on the host / scrape side. Healthy state: `up{job="smartctl-exporter"}` 8/8 = 1.

### kube-apiserver, instance talos-cp-02 (RESOLVED 2026-09-23 08:02Z)

The scrape discovers all 3 control-plane endpoints. `https://10.10.99.102:6443/healthz` was 200, but vmagent `lastError` said the `/metrics` response exceeded `-promscrape.maxScrapeSize` (16777216 bytes) for that node only, so `up{job="kube-apiserver"}` was 2/3. Not auto-fixable: raise `max_scrape_size` on the Flux-managed kube-apiserver scrape config (or the vmagent flag). Open ~76 h, 6 logged observations. Healthy state: 3/3 = 1.

## Recurrence log (open cases only)

Format and rules are in `SKILL.md` § Documented cases. No open TargetDown case at 2026-10-21. The full history of the two cases above is archived in `/opt/data/workspace/cluster-health/archive/targetdown-triage.full.md`.
