# Skill: Restore Drill

Read-only verification that CNPG database backups exist and a recovery path is viable. Does NOT perform an actual restore.

## Step 1 — Confirm Backups Exist

```bash
kubectl get backups.postgresql.cnpg.io -n <namespace>
kubectl get scheduledbackup -n <namespace>
```

A healthy backup list shows recent `Completed` entries. If empty or all `Failed`, escalate — there is no recovery path.

## Step 2 — Check Cluster Status

```bash
kubectl describe cluster <app>-pg -n <namespace>
```

Look for:

- `continuousArchiving: Archiving` — WAL is streaming to backup storage
- `lastSuccessfulBackup` timestamp — should be recent
- `phase: Cluster in healthy state`

## Step 3 — Verify WAL Archiving

```bash
kubectl exec -n <namespace> <app>-pg-1 -- \
  psql -U postgres -c "SELECT pg_walfile_name(pg_current_wal_lsn());"
```

If archiving is broken, `pg_current_wal_lsn()` advances but WAL files accumulate on the data volume — check that `walStorage` PVC isn't filling up:

```bash
kubectl exec -n <namespace> <app>-pg-1 -- df -h /var/lib/postgresql/wal
```

## Step 4 — Verify PVC Snapshots (VolSync)

If VolSync is configured for the CNPG PVC:

```bash
kubectl get replicationsource -n <namespace>
kubectl describe replicationsource <app>-pg -n <namespace>
```

Check `lastSyncTime` and `lastSyncDuration` — should show recent successful syncs.

## Step 5 — Confirm PITR Recoverability

```bash
kubectl get backup -n <namespace> -o json | \
  python3 -c "import sys,json; bs=[b for b in json.load(sys.stdin)['items'] if b['status'].get('phase')=='Completed']; print(f'{len(bs)} completed backups; oldest: {min(b[\"status\"][\"startedAt\"] for b in bs)}') if bs else print('NO COMPLETED BACKUPS')"
```

## Output

Report findings as:

```
## Restore Drill — <app> in <namespace> — <date>

Backups:      ✅ 14 completed backups; oldest 2026-05-01
WAL archiving: ✅ Active (continuousArchiving: Archiving)
WAL storage:   ✅ 28% used (2.8Gi / 10Gi)
VolSync:       ✅ Last sync 4h ago
PITR window:   ✅ 2026-05-01 → now

Recovery path: VIABLE. RPO ≈ 5 minutes (WAL archiving interval).
```

Or if issues found:

```
WAL archiving: ❌ Not configured — only full backup recovery possible, no PITR
Backups:       ⚠️  Last completed backup 8 days ago — exceeds expected cadence
```

## Notes

- This skill is read-only. Do NOT attempt a test restore unless explicitly asked — CNPG recovery overwrites the cluster.
- If backups are missing, check `scheduledbackup` resource and confirm the backup storage secret is synced via ExternalSecret.
