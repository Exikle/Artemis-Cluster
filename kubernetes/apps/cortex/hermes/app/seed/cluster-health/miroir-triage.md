# Miroir (DRBD mirror) alert triage

None of these classes is auto-fixable: the auto-fix rules forbid PVC/PV changes, so all route to `warning` ("needs human attention").

## MiroirVolumeOutOfSync (persistent over 1 h)

The alert description is the diagnosis. A peer has been out of sync for over an hour and the agent's auto-cycle did not drain it. Three branches:

1. Down peer accumulating exposure. Check all `talos-cp-*` nodes are Ready (`k8s_resources_list` v1 Node); if they are, this is not the cause.
2. Stalled resync. `miroir_volume_out_of_sync_bytes` is non-zero and `miroir_volume_resync_ratio` is 0 to 0.99.
3. Verify finding. `drbdadm verify` flagged blocks the auto-resync cannot repair. Ratio is 1 while out-of-sync bytes stay non-zero. Needs a manual disconnect/connect cycle (operator work, per the miroir troubleshooting guide).

Also check pool usage: `miroir_pool_allocated_bytes / miroir_pool_capacity_bytes * 100` per `{pool, node}`. Above ~85% writes can fail and look like a stalled resync. List volumes by `miroir_volume_out_of_sync_bytes` descending; the largest is where the operator should start, and small (under 10 MiB) ones on several replicas are usually side effects of the same verify sweep.

## MiroirPoolUsageHigh (client pool above 80%)

Recurs on the client pools of talos-w-01, talos-w-02 and talos-gpu-01. Each fire cycle lasted about 1 to 35 hours and then self-cleared as volumes moved or were cleaned up, so a single occurrence is usually not an incident. Report the live percentage (not the alert annotation, which can come from a transient burst) and how long the cycle has run. Operator fix: migrate volumes off the pool or expand the backing vdev. Last resolved 2026-10-07 16:02Z (talos-w-01).

## MiroirVolumeNotUpToDate, MiroirVolumeQuorumLost, MiroirVolumeDisconnected

Companions of the above with the same root cause. The 2026-09-09/10 QuorumLost + Disconnected set (three `*-src` snapshot-source volumes on talos-cp-02) cleared by itself.

## MiroirVolumeRemoteConsumer (severity info)

Documented design: diskless DRBD legs on consumer nodes. 28 to 32 of these fired for several days from 2026-09-11 with no action needed. Mention the count in `items` only if it changes a lot.

## Network note

The nvme-pool volumes sit on talos-cp-01/02/03 (10.10.99.101-103). An IP outside the Network map in `SKILL.md` in a Miroir alert needs a check before calling it stale.

## Recurrence log (open cases only)

Format and rules are in `SKILL.md` § Documented cases. No open Miroir case at 2026-10-21. Full history (49 entries, 2026-09-07 to 2026-10-07) is archived in `/opt/data/workspace/cluster-health/archive/miroir-triage.full.md`.
