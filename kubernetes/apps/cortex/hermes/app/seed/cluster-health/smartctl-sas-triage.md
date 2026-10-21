# SmartScsiGrownDefectsIncreasing (pantheon SAS drives)

Not auto-fixable: it is a media-wear signal on the Proxmox host `pantheon`, outside the cluster.

## Verify

- `smartctl_scsi_grown_defect_list{instance="pantheon"}` per device. SAS devices with the metric: sda, sdg, sdh, sdf (NVMe devices have none).
- `smartctl_device_smart_status{instance="pantheon"}`: all 8 should be 1 (PASSED). A 0 is a real failure; escalate.
- The alert fires on a rolling 24 h increase and cleared on 2026-10-17 after about 6 days with no further growth.

## State at 2026-10-17

sdh plateaued at 8 (cycles closed at 5 on 2026-09-25, 6 on 2026-10-07, 7 on 2026-10-10, 8 on 2026-10-17). sdf plateaued at 10 since 2026-09-08. sda = sdg = 0. All devices SMART PASSED. RESOLVED 2026-10-17 12:02Z, no action required from this skill. A new fire cycle means sdh (or another device) grew again: report the new count and the number of cycles so far, and note the pattern suggests slow wear on the shelf for the operator to watch.

Older detail: `/opt/data/workspace/cluster-health/archive/smartctl-sas-triage.full.md`.
