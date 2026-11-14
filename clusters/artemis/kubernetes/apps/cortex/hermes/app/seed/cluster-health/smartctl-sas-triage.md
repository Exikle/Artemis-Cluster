# SmartScsiGrownDefectsIncreasing (pantheon SAS drives)

This alert is not auto-fixable. It is a media-wear signal on the Proxmox host `pantheon`, outside the cluster.

## Verify

- `smartctl_scsi_grown_defect_list{instance="pantheon"}` per device. SAS devices with the metric: sda, sdg, sdh, sdf (NVMe devices have none).
- `smartctl_device_smart_status{instance="pantheon"}`: all 8 must be 1 (PASSED). A 0 is a real failure. Escalate it.
- The alert fires on a rolling 24 h increase. It cleared on 2026-10-17 after about 6 days with no further growth.

## State at 2026-10-17

sdh plateaued at 8 (cycles closed at 5 on 2026-09-25, 6 on 2026-10-07, 7 on 2026-10-10, 8 on 2026-10-17). sdf plateaued at 10 since 2026-09-08. sda = sdg = 0. All devices SMART PASSED. RESOLVED 2026-10-17 12:02Z, no action required from this skill. If a new fire cycle starts, sdh (or another device) grew again. Report the new count and the number of cycles so far. Note that the pattern suggests slow wear on the shelf for the operator to watch.

Older detail: `/opt/data/workspace/cluster-health/archive/smartctl-sas-triage.full.md`.
