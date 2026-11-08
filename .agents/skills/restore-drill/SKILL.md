---
name: restore-drill
description: Check whether backups are in a state that could actually be restored — CNPG backup and WAL archiving status, and kopiur snapshot freshness. Use for "backup health check", "CNPG backup status", "restore drill", "are backups working", or "WAL archiving". It reports. It does not restore. To actually restore, use `kopiur-restore`. For overall cluster health rather than backups, use `cluster-status`. Scoped to the Artemis cluster.
compatibility: Read-only. It uses plain `kubectl get` against the CNPG and kopiur CRDs, and needs no plugin. It does not perform a test restore, because CNPG recovery overwrites the cluster. Do that only on an explicit request.
---

# Skill: Restore Drill

This skill is a read-only check that CNPG database backups exist and that a recovery path is viable. It does NOT perform an actual restore.

## Step 1: Confirm Backups Exist

```bash
kubectl get backups.postgresql.cnpg.io -n <namespace>
kubectl get scheduledbackup -n <namespace>
```

A healthy backup list shows recent `Completed` entries. If the list is empty or all entries are `Failed`, escalate. There is no recovery path.

## Step 2: Check Cluster Status

```bash
kubectl describe cluster postgres -n database   # the only CNPG cluster since 2026-09-01
```

Look for:

- `continuousArchiving: Archiving`: WAL streams to backup storage
- `lastSuccessfulBackup` timestamp: it must be recent
- `phase: Cluster in healthy state`

## Step 3: Verify WAL Archiving

```bash
kubectl exec -n database postgres-1 -- \
  psql -U postgres -c "SELECT pg_walfile_name(pg_current_wal_lsn());"
```

The direct signal is the ready-segment count. Any count above zero means that the archive has stalled
and WAL is piling up:

```bash
kubectl exec -n database postgres-1 -- \
  psql -U postgres -tAc "SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready';"
kubectl exec -n database postgres-1 -- df -h /var/lib/postgresql/wal
```

Since 2026-09-01, WAL has its own 8Gi volume. A stall fills that volume, not the data volume, and
`CNPGWalArchiveBacklog` / `CNPGDataVolumeFillingUp` page before it matters. Do **not** alert on
`seconds_since_last_archival`. An idle database skips the `archive_timeout`-forced WAL switch, and
that metric climbs past the timeout although nothing is wrong.

## Step 4: Verify PVC Snapshots (kopiur)

If kopiur is configured for the CNPG PVC:

```bash
kubectl get snapshot,snapshotpolicy,snapshotschedule -n <namespace>
kubectl describe snapshotpolicy <app> -n <namespace>
```

The VolSync `ReplicationSource`/`ReplicationDestination` objects are **gone**. The repo removed VolSync
on 2026-08-01 and those CRDs do not exist in this cluster. The kopiur equivalents are `Snapshot`
(one backup run), `SnapshotPolicy` (what and how, per app), `SnapshotSchedule` (when) and `Restore`.
The `components/kopiur/backup` component creates the policy, schedule, PVC and `Restore` from
`${APP}`.

Check the `SnapshotPolicy` status for a recent successful snapshot, and make sure that the newest
`Snapshot` for the app completed. A policy with no recent Snapshot is the failure to catch.

## Step 5: Confirm PITR Recoverability

```bash
kubectl get backup -n <namespace> -o json | \
  python3 -c "import sys,json; bs=[b for b in json.load(sys.stdin)['items'] if b['status'].get('phase')=='Completed']; print(f'{len(bs)} completed backups; oldest: {min(b[\"status\"][\"startedAt\"] for b in bs)}') if bs else print('NO COMPLETED BACKUPS')"
```

## Output

Report findings in this format:

```
## Restore Drill — <app> in <namespace> — <date>

Backups:      ✅ 14 completed backups; oldest 2026-05-01
WAL archiving: ✅ Active (continuousArchiving: Archiving)
WAL storage:   ✅ 28% used (2.8Gi / 10Gi)
kopiur:        ✅ Last snapshot 4h ago
PITR window:   ✅ 2026-05-01 → now

Recovery path: VIABLE. RPO ≈ 5 minutes (WAL archiving interval).
```

If you find issues, report them like this:

```
WAL archiving: ❌ Not configured — only full backup recovery possible, no PITR
Backups:       ⚠️  Last completed backup 8 days ago — exceeds expected cadence
```

## Notes

- This skill is read-only. Do NOT attempt a test restore unless the user explicitly asks. CNPG recovery overwrites the cluster.
- If backups are missing, check the `scheduledbackup` resource and make sure that the ExternalSecret synced the backup storage secret.
