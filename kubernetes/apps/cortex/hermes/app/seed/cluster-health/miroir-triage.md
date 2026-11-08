# Miroir (DRBD mirror) alert triage

None of these classes is auto-fixable, because the auto-fix rules forbid PVC/PV changes. All of them route to `warning` ("needs human attention").

## MiroirVolumeOutOfSync (persistent over 1 h)

The alert description is the diagnosis. A peer is out of sync for over an hour and the auto-cycle of the agent did not drain it. There are three branches:

1. Down peer accumulating exposure. Make sure that all `talos-cp-*` nodes are Ready (`k8s_resources_list` v1 Node). If they are, this is not the cause.
2. Stalled resync. `miroir_volume_out_of_sync_bytes` is non-zero and `miroir_volume_resync_ratio` is 0 to 0.99.
3. Verify finding. `drbdadm verify` flagged blocks that the auto-resync cannot repair. The ratio is 1 while the out-of-sync bytes stay non-zero. This needs a manual disconnect/connect cycle (operator work, per the miroir troubleshooting guide).

Also check the pool usage: `miroir_pool_allocated_bytes / miroir_pool_capacity_bytes * 100` per `{pool, node}`. Above ~85%, writes can fail and look like a stalled resync. List volumes by `miroir_volume_out_of_sync_bytes` descending. The largest is where the operator must start. Small ones (under 10 MiB) on several replicas are usually side effects of the same verify sweep.

## MiroirPoolUsageHigh (client pool above 80%)

Recurs on the client pools of talos-w-01, talos-w-02 and talos-gpu-01. Each fire cycle lasted about 1 to 35 hours and then cleared by itself as volumes moved or were cleaned up, so a single occurrence is usually not an incident. Report the live percentage (not the alert annotation, which can come from a transient burst) and how long the cycle runs. Operator fix: migrate volumes off the pool or expand the backing vdev. Last resolved 2026-10-07 16:02Z (talos-w-01).

## MiroirVolumeNotUpToDate, MiroirVolumeQuorumLost, MiroirVolumeDisconnected

These alerts accompany the ones above and have the same root cause. The 2026-09-09/10 QuorumLost + Disconnected set (three `*-src` snapshot-source volumes on talos-cp-02) cleared by itself.

## MiroirVolumeRemoteConsumer (severity info)

This is the documented design: diskless DRBD legs on consumer nodes. 28 to 32 of these alerts fired for several days from 2026-09-11, and no action was needed. Mention the count in `items` only if it changes a lot.

## Network note

The nvme-pool volumes sit on talos-cp-01/02/03 (10.10.99.101-103). If a Miroir alert shows an IP that is outside the Network map in `SKILL.md`, check it before you call it stale.

## Recurrence log (open cases only)

Format and rules are in `SKILL.md` § Documented cases. No open Miroir case at 2026-10-21. Full history (49 entries, 2026-09-07 to 2026-10-07) is archived in `/opt/data/workspace/cluster-health/archive/miroir-triage.full.md`.
