# Node baselines (Artemis cluster)

A condensed knowledge bank of NodeTop snapshots across recent hourly audits.
Use this to **phrase deviations** in the quiet-run `items` block without
re-grepping `targetdown-triage.md` for the same numbers.

Always re-verify the current snapshot from `k8s_nodes_top` at the start of the
run — these baselines are the **anchor for "above baseline / consistent with
baseline / new deviation"** wording, not a substitute for the live read.

## 7-node topology (re-verify the count every run)

`talos-cp-01/02/03` (.101/.102/.103, control-plane, M710q metal)
`talos-w-01/02` (.201/.202, worker VMs on pantheon)
`talos-gpu-01` (.203, GPU worker VM on pantheon)
`ymir` (.204, worker, metal-04)

Expect **7 nodes**, never trust a count copied from a prior log entry —
re-read `k8s_resources_list v1 Node` and count NAME fields yourself.

## Recent baselines (per-node, last ~10 hourly runs)

| Node         | CPU observed range   | CPU peak(s)          | MEM observed range | Notes                                                                                                                                                                                                                                                                                                    |
| ------------ | -------------------- | -------------------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| talos-cp-01  | ~23–32%              | —                    | 56–70%             | Mem now spans 56–70% — 2026-08-17 dropped to 56% (low-side deviation, still no pressure); 64–66% steady band documented earlier; **70% observed 2026-08-17 18:00 UTC** (slight uptick above the 64–66% band + occasional 68% noted, still no pressure); 2026-08-17 11:01 UTC: 32% CPU / 64% mem          |
| talos-cp-02  | 31%                  | —                    | 62–64%             | Not historically in the elevated set                                                                                                                                                                                                                                                                     |
| talos-cp-03  | 34%                  | —                    | 53%                | Quietest CP; no history of pressure                                                                                                                                                                                                                                                                      |
| talos-w-01   | 54%                  | —                    | 28%                | Stable                                                                                                                                                                                                                                                                                                   |
| talos-w-02   | 27–55%, 63%, **70%** | 70% noted 2026-08-17 | 30–33%             | 55% spike was annotated "elevated vs usual ~27%"; 70% is a new deviation above the 63% prior peak — annotate as "new deviation" rather than the historical "elevated vs usual ~27%" phrasing, since 70% now exceeds the prior peak rather than the usual band                                            |
| talos-gpu-01 | **51–68% baseline**  | 81–88%, 93%, 96%     | 29–39%             | 2026-08-17 11:01 UTC: 87% CPU / 38% mem — **new peak in the 81–88% band** (prior peaks were 81–84% on 2026-08-15 and 88% on 2026-08-17 03:05 UTC, plus 93–96% historical); still below the >90% "elevated" threshold so phrase as "above the 51–68% recent baseline, still no pressure"; see notes below |
| ymir         | 9–10%                | —                    | 42–46%             | Low-load worker, 4d6h old as of 2026-08-17 11:01 UTC; mem dipped to 42% — within noise                                                                                                                                                                                                                   |

## talos-gpu-01 — the trend to watch

- **Baseline after the 2026-08-13 drop:** 51–68% CPU, ~30% mem.
- **Pre-drop peaks:** 93% (9th entry, 2026-08-14), 96% (7th entry, 2026-08-14).
- **Annotation phrasing that worked:**
    - Within 51–68% → `"consistent with prior entries, no pressure"`
    - 69–88% → `"above the 51–68% recent baseline, still no pressure"`
      (observed: 81–84% on 2026-08-15 follow-up, 88% on 2026-08-17 03:05 UTC,
      **87% on 2026-08-17 11:01 UTC** — all three used this phrasing without
      the operator escalating)
    - > 90% → `"elevated, no pressure — consistent with prior peaks"` OR
      > `"new deviation"` if the dwell time at >90% extends past an hour.
- **Mem on the same node** has stayed 29–39% across all entries —
  elevated CPU without proportional mem growth = a workload-level blip,
  not a node sizing problem.

## talos-cp-01 — mem drift

- 64–66% for many entries, occasional 68%. 2026-08-17 18:00 UTC observed 70% — slight uptick above the 64–66% band + occasional 68% noted, still no pressure.
- No pressure condition reported (kubelet would evict at 100% memory.available
  based thresholds, well above this).
- Annotation for the steady band: `"consistent with prior entries (64–66%)"`.
- Annotation for a 70% reading (above the band's ceiling by ~2pp but well below any eviction threshold): `"slight uptick above the 64–66% documented band (occasional 68% noted), still no pressure"` — phrase used without operator escalation on 2026-08-17 18:00 UTC. Do NOT escalate unless the reading sustains above 75% or crosses a documented severity threshold.

## Using this file

When the current `k8s_nodes_top` shows a value outside the documented band:

1. Re-check that you read node-top at the right moment (it polls every ~15s;
   transient spikes of 1–2 minutes are noise, not a deviation).
2. Pick the right phrasing from the table above — do NOT invent a new range.
3. If the deviation is sustained AND touches a severity-relevant threshold
   (>90% CPU for an hour, >85% mem sustained), surface as a fresh deviation
   in items, not just as expected cluster noise.

## What this file is NOT

- **Not a substitute for re-verifying live state.** The first action in any
  audit is to read `k8s_nodes_top` fresh — these numbers are the _baseline
  to compare against_, never the _current snapshot_.
- **Not authoritative on alert firing thresholds.** Pressure conditions
  (MemoryPressure / DiskPressure / PIDPressure on Node conditions) are the
  source of truth for "needs human attention"; elevated utilization alone
  is not.
