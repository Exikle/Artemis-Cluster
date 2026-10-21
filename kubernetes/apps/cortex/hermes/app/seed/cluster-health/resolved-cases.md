# Case index (read this on every run; one row per case, one line each)

## Open cases

Cases currently firing or recently logged and not yet RESOLVED. For each one that is absent from the firing set, follow SKILL.md "no longer firing". Add a row when you log a case's first recurrence; move it to the table below when you write its RESOLVED entry.

| Alert / target       | First seen | Detail |
| -------------------- | ---------- | ------ |
| (none at 2026-10-21) |            |        |

## Resolved cases

When a case here is absent from the firing set, run its verify query once and put one line in `items`. Do not append to any log. If the alert fires again, move the row back to Open cases and log a recurrence in its detail file.

| Alert / target                                                   | Resolved                | Verify (VictoriaMetrics, port 8428)                                                            | Detail                       |
| ---------------------------------------------------------------- | ----------------------- | ---------------------------------------------------------------------------------------------- | ---------------------------- |
| TargetDown `smartctl-exporter` (static `instance=pantheon`)      | 2026-08-15              | `up{job="smartctl-exporter"}` 8/8 = 1                                                          | targetdown-triage.md         |
| TargetDown `kube-apiserver` (talos-cp-02 `/metrics` over 16 MiB) | 2026-09-23              | `up{job="kube-apiserver"}` 3/3 = 1                                                             | targetdown-triage.md         |
| EtcdDatabaseHighFragmentationRatio (cp-01/02/03)                 | 2026-09-23              | alert absent; ratio `etcd_mvcc_db_total_size_in_use_in_bytes/etcd_mvcc_db_total_size_in_bytes` | etcd-triage.md               |
| MiroirPoolUsageHigh (client pools; recurs, self-clears)          | 2026-10-07 (talos-w-01) | alert absent; pool % = `miroir_pool_allocated_bytes/miroir_pool_capacity_bytes*100` below 80   | miroir-triage.md             |
| PocketIDOIDCClientPKCESupported (all 4 OIDC clients)             | 2026-10-16              | alert absent                                                                                   | pocket-id-operator-triage.md |
| SmartScsiGrownDefectsIncreasing (pantheon sdh; 4 fire cycles)    | 2026-10-17              | alert absent; `smartctl_scsi_grown_defect_list{device="sdh",instance="pantheon"}` still 8      | smartctl-sas-triage.md       |
