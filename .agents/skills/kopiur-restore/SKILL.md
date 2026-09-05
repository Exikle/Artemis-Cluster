---
name: kopiur-restore
description: Restore a PVC from a kopiur backup or snapshot — recovering an app's data after loss, corruption, or a bad change, or pulling a single file out of a snapshot without disturbing the running app. Use for "restore X from backup", "restore from kopiur", "kopiur restore", "recover PVC", "recover X's data", "roll back X's data", "undo a bad migration", "get the old database out of a snapshot", or "the PVC is empty". Scoped to the Artemis cluster.
---

# Skill: Kopiur Restore

Restore a kopiur-managed PVC from a snapshot in **Artemis-Cluster**, or extract a single file from
a snapshot while the app keeps running.

> Read `.agents/references/kopiur.md` first — mover identity, `restore.yaml` uid rules, and why a
> completed `Restore` is never re-reconciled. `.agents/references/storage.md` § Binding mode
> decides how a restore is driven covers the `ceph-block` vs `miroir` split below.

> **Check the PVC's StorageClass before you start.** On `ceph-block` (`Immediate`) a restore runs
> with the workload scaled to **0**. On `miroir` / `miroir-local` (`WaitForFirstConsumer`) the PVC
> and the `Restore` both sit `Pending` until a consumer is scheduled, so the workload must be
> scaled **back up** to drive the restore — leaving it at 0 deadlocks forever.

The default kubeconfig context is `artemis`; confirm with `kubectx` before running anything
destructive.

## Pick the right shape first

Two very different jobs. Choosing wrong costs an outage you did not need.

| You want                                          | Use                         | App downtime      |
| ------------------------------------------------- | --------------------------- | ----------------- |
| The live PVC's contents replaced wholesale        | **§ Full restore**          | Yes — scaled to 0 |
| One file (a database, a config) out of a snapshot | **§ Extract-only recovery** | **None**          |

**Most "recover my data" requests are extract-only.** If the app is running fine and you just need
rows or a file from before a bad change, do not scale anything down and do not touch the live
claim. Restore into a _separate_ PVC and copy what you need out.

## Critical rules

- **Everything below goes through git, not a direct cluster write.** `.claude/hooks/bash-guard.sh`
  blocks direct applies in this repo — that is deliberate, not an obstacle to route around. Put the
  recovery objects in a temporary directory under the app, then `just kube apply-ks`, which renders
  from **local files** and therefore needs no CI round-trip. Clean up with `just kube delete-ks`
  plus a removal commit. Worked example in § Extract-only recovery.
- **The guard also matches `git commit -m` message text.** A commit message that merely _quotes_ a
  guarded command is blocked. Use `git commit -F -` with a heredoc — the guard strips heredoc
  bodies.
- **Always use `target.pvcRef`** — `target.pvc` creates an OWNED PVC that is garbage-collected when
  the Restore completes, deleting your data. Pre-create the PVC and point `pvcRef` at it.
- **Do NOT set `credentialProjection` when the mover namespace already has its own
  `kopiur-repository-secret`.** See § Credentials — this is the single most likely thing to stall a
  restore.
- kopiur mover cache defaults to `1Mi` — set `mover.cache.capacity: 2Gi` in the SnapshotPolicy or
  the snapshot fails with disk quota exceeded.
- For postgres PVCs (uid 999, mode 700): `copyMethod: Snapshot` plus
  `moverSecurityContext: runAsUser: 999, runAsGroup: 999`.
- `copyMethod: Direct` cannot remount a live RWO volume. Scale to 0, or use `copyMethod: Snapshot`.
- Artemis has three StorageClasses while the miroir migration runs (issue #1981): `ceph-block`
  (RBD, default, `Immediate`), `miroir` and `miroir-local` (lvmthin, `WaitForFirstConsumer`).
  There is no `ceph-filesystem`. `kubectl get sc` is the live answer.
- Flux Kustomizations live in the app's **target namespace**. Look up the real name:
  `grep "^  name:" kubernetes/apps/<ns>/<app>/ks.yaml`.
- `just kube apply-ks` suspends the root Kustomization and the target child. Finish with
  `just kube resume-ks`, and **commit and push before resuming** — resuming while your change is
  only local makes Flux revert it.

## Credentials — read this before writing a Restore

The `atlas` ClusterRepository points `encryption.passwordSecretRef` at
`kopiur-system/kopiur-repository-secret`. Namespaces that back up (via `components/kopiur/secret`)
also carry their **own identical copy** of that secret.

- **Secret already in the mover namespace** (the normal case for `media`, `default`, `fediverse`):
  **omit `credentialProjection` entirely.** The mover uses the local secret.
- **Secret not in the namespace**: the ClusterRepository must allow it —
  `credentialProjection.allowed: true` — _and_ the Restore sets `credentialProjection.enabled:
true`. Without the owner-side allow, setting `enabled` on its own fails.

Setting `credentialProjection.enabled: true` when the local secret exists does **not** fall back
gracefully. It requests cross-namespace access, the ClusterRepository denies it, and the Restore
sits in `Pending` with:

```
CredentialsAvailable=False MissingCredentialsSecret: cross-namespace credential projection denied
```

…while a perfectly good identical secret sits unused in the namespace. Deleting the field is the
whole fix.

## Reading a snapshot without restoring it

`kubectl kopiur ls|cat|download|browse` are read-only and would be the quick path, but **both modes
are currently unavailable for namespaced snapshots here**:

- `--local` fails: the `atlas` backend is an in-cluster NFS volume that a workstation cannot mount.
- The default in-cluster session pod fails on the same cross-namespace secret wall as above.

Setting `credentialProjection.allowed: true` on the ClusterRepository would unlock them. Until
then, use § Extract-only recovery.

## Step 1 — Confirm

Ask: **app** and **namespace**, **which PVC**, **which snapshot**, and the **reason**. Then decide
full restore vs extract-only using the table at the top.

For a full restore, warn that it overwrites current PVC contents and get explicit confirmation.

## Step 2 — Find the snapshot

```bash
kubectl get snapshots.kopiur.home-operations.com -n <ns> | grep <app>
```

Names are `<app>-YYYYMMDDHHMMSS` in **UTC**. Convert before choosing — picking a snapshot an hour
on the wrong side of the incident is the classic mistake. Sanity-check against the `AGE` column.

---

## Extract-only recovery (no downtime)

Restores a snapshot into a throwaway PVC, then copies one file out. The live claim and the running
app are never touched.

### 1. Stage the objects in git

Create `kubernetes/apps/<ns>/<app>/recovery/` with a `kustomization.yaml` listing:

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
    name: <app>-recovery
spec:
    accessModes:
        - ReadWriteOnce
    resources:
        requests:
            storage: <same size as the live claim>
    storageClassName: ceph-block
---
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Restore
metadata:
    name: <app>-recovery
spec:
    source:
        snapshotRef:
            name: <snapshot-name>
    target:
        pvcRef:
            name: <app>-recovery
```

Note there is **no `credentialProjection`** — see § Credentials.

Add a Kustomization document to the app's `ks.yaml` pointing at `./recovery`, then commit and push.

### 2. Apply and watch

```bash
just kube apply-ks <ns> <app>-recovery
kubectl get restore -n <ns> <app>-recovery -o jsonpath='{.status.phase}'
```

`Pending` → `Restoring` → `Completed`. If it stays `Pending`, read
`.status.conditions[].message` — it names the cause precisely.

### 3. Copy the file out

```bash
kubectl run -n <ns> <app>-recovery-reader --restart=Never \
  --image=mirror.gcr.io/alpine:latest \
  --overrides='{"spec":{"containers":[{"name":"<app>-recovery-reader","image":"mirror.gcr.io/alpine:latest","command":["sleep","900"],"volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"<app>-recovery"}}]}}'

kubectl exec -n <ns> <app>-recovery-reader -- ls -la /mnt
kubectl cp -n <ns> "<app>-recovery-reader:/mnt/<path>" ./<file>
```

**For SQLite, copy all three files** — `<db>`, `<db>-shm`, `<db>-wal` — and verify each landed with
the expected size. A copy missing its WAL reads as an older, smaller database and can also report
`database disk image is malformed`. Suppressing `kubectl cp` errors hides this; do not.

### 4. Clean up

```bash
kubectl delete pod -n <ns> <app>-recovery-reader --wait=false
just kube delete-ks <ns> <app>-recovery
```

Then delete `recovery/`, remove the Kustomization document from `ks.yaml` (keep the leading `---`
on the first remaining document), commit, push, and `just kube resume-ks`.

---

## Full restore (replaces the live PVC)

Only when the live claim's contents must be replaced.

### 1. Scale the app down

Set `replicas: 0` **in git** and push. A bare `kubectl scale` is reverted by Flux on its next
reconcile, restarting the pod mid-restore.

```bash
kubectl get pods -n <ns>   # wait until none remain
```

### 2. Retain the PV, delete the old PVC

```bash
kubectl patch pv <pv-name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl delete pvc <pvc-name> -n <ns>
```

Stuck `Terminating` usually means a completed mover pod still holds the `pvc-protection`
finalizer — delete that pod.

### 3. Recreate the PVC and Restore

Same two objects as the extract-only path, but named as the app's real claim, staged in git and
applied with `just kube apply-ks`. Do **not** use `dataSourceRef`: the Restore populates via the
mover, not the populator API.

### 4. Scale back up and verify

Restore `replicas: 1` in git, push, then check the app's own API or logs — not just pod readiness.

## After any restore into a database-backed app

**Apps cache configuration at boot.** If you restore or load data underneath a running app, restart
it or it will keep serving the state it read at startup. Sonarr and Radarr report _"No indexers
available"_ with indexers sitting in the database; bazarr loses its language profile. A
`kubectl rollout restart deployment/<app> -n <ns>` is part of the job, not an afterthought.

**Verify row counts per table, not the exit code.** A load can report success and still be wrong.

## Common issues

- **Restore stuck `Pending`, `MissingCredentialsSecret`** — `credentialProjection` set when the
  namespace already has the secret. Remove the field. See § Credentials.
- **Snapshot stuck with `snapshot-cleanup` finalizer**:
  `kubectl patch snapshot <name> -n <ns> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'`
- **Mover pod `Init:0/1` with FailedMount** — volume still mounted elsewhere; scale to 0 first.
- **`disk quota exceeded`** — SnapshotPolicy missing `mover.cache.capacity: 2Gi`.
- **Restore stuck Pending** — check the source snapshot is `Succeeded`, not `Failed`.
- **Recovered data vanishes when the Restore completes** — `target.pvc` was used instead of
  `target.pvcRef`. The owned PVC was garbage-collected.
