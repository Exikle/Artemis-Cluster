# Node baselines

Read `k8s_nodes_top` fresh every run. These ranges only supply wording for `items`; they never replace the live reading. Escalation comes from node conditions (MemoryPressure, DiskPressure, PIDPressure), not from utilization alone.

Nodes (expect 7; count them from the live result): talos-cp-01/02/03 (metal control plane), talos-w-01, talos-w-02, talos-gpu-01 (VMs on pantheon), ymir (metal).

## Typical ranges (observed 2026-08 to 2026-10; approximate, refresh when a node sits outside its range for days)

| Node         | CPU    | Memory |
| ------------ | ------ | ------ |
| talos-cp-01  | 23-35% | 56-73% |
| talos-cp-02  | 28-39% | 49-64% |
| talos-cp-03  | 21-34% | 34-53% |
| talos-w-01   | 26-54% | 25-30% |
| talos-w-02   | 18-55% | 27-33% |
| talos-gpu-01 | 46-68% | 26-39% |
| ymir         | 46-56% | 42-85% |

Known bursts that were not incidents: talos-gpu-01 CPU 69-96%, talos-w-01 CPU up to 72%, ymir CPU up to 89-100%. Memory on ymir has run 71-83% for weeks.

## Wording (pick the line whose range contains the number)

- Inside the table range: `"consistent with prior entries, no pressure"`.
- Above the range but CPU 90% or lower, memory 85% or lower: `"above the <low>-<high>% recent range, still no pressure"`.
- CPU above 90% for a full hour, or memory above 85% sustained: `"new deviation"` and put it high in `items`.
- Below the range: `"below the usual range, no pressure"`.
- Elevated CPU with memory flat is a workload burst, not a sizing problem; say so in a few words.

A transient 1-2 minute spike in `k8s_nodes_top` is noise. Never describe a reading as "back in" a range its number is outside of (75% is not back in 51-68%).
