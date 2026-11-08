---
name: kopiur-restore
description: Restore a PVC from a kopiur backup or snapshot, to recover an app's data after loss, corruption, or a bad change, or to pull a single file out of a snapshot without disturbing the running app. Use for "restore X from backup", "restore from kopiur", "kopiur restore", "recover PVC", "recover X's data", "roll back X's data", "undo a bad migration", "get the old database out of a snapshot", or "the PVC is empty". This is the default for any restore request. Use `recreate-pvc` only when the volume's StorageClass parameters are the thing being changed, and `restore-drill` when the question is whether backups work rather than restoring one. Scoped to the Artemis cluster.
compatibility: Requires the kopiur CRDs and the shared `ClusterRepository/atlas` secret. The core restore path is plain CRs; the `kubectl kopiur ls|cat|download|browse` plugin is needed only for the single-file path.
---

# Skill: Kopiur Restore

Restore a kopiur-managed PVC from a snapshot in Artemis-Cluster, or extract a single file from
a snapshot while the app keeps running.

> Read `.agents/references/kopiur.md` first. It covers mover identity, `restore.yaml` uid rules, and why a
> completed `Restore` is never re-reconciled. `.agents/references/storage.md` § Binding mode
> explains why you must drive a populator restore with the workload scaled back up.

> The direction to scale depends on how the PVC is driven.
>
> - `target.populator` Restore into a new, unbound PVC: scale the workload UP. Both
>   StorageClasses are `WaitForFirstConsumer`, so the PVC stays `Pending` until a consumer is
>   scheduled. If the workload stays at 0, the restore deadlocks. A populator only hands a volume to an _unbound_
>   claim.
> - Existing, bound PVC restored in place: scale to 0, which is what
>   `just kube restore-pvc` does. The mover pod is the consumer, and the app must not write
>   while its data is replaced.
> - `target.pvcRef` Restore into a pre-created PVC (§ Extract-only recovery): this is not a populator.
>   The mover pod mounts the claim, and it is the first consumer. A fresh, unbound `miroir` claim
>   binds within seconds of the mover pod scheduling, and the Restore reaches `Completed` with no
>   reader pod and nothing to scale. Verified 2026-10-15
>   ([#2769](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2769)).

The default kubeconfig context is `artemis`. Run `kubectx` to confirm it before you run anything
destructive.

Goal: get one PVC's data back from a kopiur snapshot, or pull specific files out of one.

Success means that the app runs against restored data and the user has confirmed the
contents are what they expected. You cannot confirm that yourself. Only the user knows whether
the restored state is the right point in time.

Stop when the workload is Running on the restored PVC and you have reported which snapshot
you used. Do NOT delete the old PVC, the snapshot, or any `Restore` object afterwards. Flux never re-reconciles a
completed `Restore`, so if you delete it, you remove the only record of what ran.

## Pick the right shape first

There are two very different jobs. If you choose wrong, you cause an outage you did not need.

| You want                                          | Use                         | App downtime     |
| ------------------------------------------------- | --------------------------- | ---------------- |
| The live PVC's contents replaced wholesale        | **§ Full restore**          | Yes, scaled to 0 |
| One file (a database, a config) out of a snapshot | **§ Extract-only recovery** | **None**         |

Most "recover my data" requests are extract-only. If the app runs fine and you only need
rows or a file from before a bad change, do not scale anything down and do not touch the live
claim. Restore into a _separate_ PVC and copy what you need out.

## Critical rules

- Everything below goes through git, not a direct cluster write. The global `~/.claude/hooks/bash-guard.sh`
  blocks direct applies in this repo. This is deliberate, so do not route around it. Put the
  recovery objects in a temporary directory under the app, then run `just kube apply-ks`. It renders
  from local files and therefore needs no CI round-trip. Clean up with `just kube delete-ks`
  plus a removal commit. § Extract-only recovery has a worked example.
- The guard also matches `git commit -m` message text. It blocks a commit message that only _quotes_ a
  guarded command. Use `git commit -F -` with a heredoc. The guard strips heredoc
  bodies.
- Always use `target.pvcRef`. `target.pvc` creates an OWNED PVC that Kubernetes garbage-collects when
  the Restore completes, and that deletes your data. Pre-create the PVC and point `pvcRef` at it.
- Do NOT set `credentialProjection` when the mover namespace already has its own
  `kopiur-repository-secret`. See § Credentials. This is the most likely cause of a stalled
  restore.
- For postgres PVCs (uid 999, mode 700), use `copyMethod: Snapshot` plus
  `moverSecurityContext: runAsUser: 999, runAsGroup: 999`.
- `copyMethod: Direct` cannot remount a live RWO volume. Scale to 0, or use `copyMethod: Snapshot`.
- Artemis has two StorageClasses, both `WaitForFirstConsumer`: `miroir` (default, 2 replicas) and
  `miroir-local` (1 replica). There is no RWX class. `kubectl get sc` gives the live answer.
- Flux Kustomizations live in the app's target namespace. Look up the real name:
  `grep "^  name:" kubernetes/apps/<ns>/<app>/ks.yaml`.
- Suspend, apply, confirm, commit, wait for the artifact and resume as
  `.agents/instructions/commit-style.md` § The sequence describes. Do not resume until the artifact carries
  your commit. If you resume earlier, Flux reverts the change.
- Edit in a worktree: run `just wt new fix/<slug>` first (`AGENTS.md` rule 7).

## Credentials: read this before you write a Restore

The `atlas` ClusterRepository points `encryption.passwordSecretRef` at
`kopiur-system/kopiur-repository-secret`. Namespaces that back up (through `components/kopiur/secret`)
also carry their own identical copy of that secret.

- If the secret is already in the mover namespace (the normal case for `media`, `default`, `fediverse`),
  omit `credentialProjection` entirely. The mover uses the local secret.
- If the secret is not in the namespace, the ClusterRepository must allow it with
  `credentialProjection.allowed: true`, and the Restore must set `credentialProjection.enabled:
  true`. Without the owner-side allow, setting `enabled` on its own fails.

If you set `credentialProjection.enabled: true` when the local secret exists, the restore does not fall back
to the local secret. It requests cross-namespace access, the ClusterRepository denies it, and the Restore
stays in `Pending` with:

```
CredentialsAvailable=False MissingCredentialsSecret: cross-namespace credential projection denied
```

A good identical secret sits unused in the namespace. To fix it, delete the field.

## Reading a snapshot without restoring it

`kubectl kopiur ls|cat|download|browse` are read-only and would be the quick path, but both modes
are currently unavailable for namespaced snapshots here:

- `--local` fails because the `atlas` backend is an in-cluster NFS volume that a workstation cannot mount.
- The default in-cluster session pod fails on the same cross-namespace secret wall as above.

Setting `credentialProjection.allowed: true` on the ClusterRepository would unlock them. Until
then, use § Extract-only recovery.

## Step 1: Confirm

Ask for the app and namespace, which PVC, which snapshot, and the reason. Then use the table at the top to decide
between a full restore and extract-only.

For a full restore, warn that it overwrites current PVC contents and get explicit confirmation.

## Step 2: Find the snapshot

```bash
kubectl get snapshots.kopiur.home-operations.com -n <ns> | grep <app>
```

Names are `<app>-YYYYMMDDHHMMSS` in UTC. Convert before you choose. The classic mistake is to pick a snapshot an hour
on the wrong side of the incident. Compare your choice with the `AGE` column.

---

## Extract-only recovery (no downtime)

This restores a snapshot into a throwaway PVC, then copies one file out. It never touches the live claim or the running
app.

### 1. Stage the objects locally

Create `kubernetes/apps/<ns>/<app>/recovery/` with a `kustomization.yaml` that lists:

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
    storageClassName: miroir
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

There is no `credentialProjection` here. See § Credentials.

Add a Kustomization document to the app's `ks.yaml` that points at `./recovery`.

### 2. Apply and watch

The recovery Kustomization exists only locally. Suspend the root first, or its next reconcile
prunes the recovery objects mid-restore:

```bash
just kube suspend-ks flux-system flux-system
just kube apply-ks <ns> <app>-recovery
kubectl get restore -n <ns> <app>-recovery -o jsonpath='{.status.phase}'
```

The phase goes from `Restoring` to `Completed`, in about two minutes for a 1Gi claim. The PVC stays `Pending` only until the
mover pod schedules, so do not create the reader first. If the Restore stays `Pending`, read
`.status.conditions[].message`. It names the cause precisely. If the Restore goes `Failed`, see
§ Common issues.

### 3. Copy the file out

```bash
kubectl run -n <ns> <app>-recovery-reader --restart=Never \
  --image=mirror.gcr.io/alpine:latest \
  --overrides='{"spec":{"containers":[{"name":"<app>-recovery-reader","image":"mirror.gcr.io/alpine:latest","command":["sleep","900"],"volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"<app>-recovery"}}]}}'

kubectl exec -n <ns> <app>-recovery-reader -- ls -la /mnt
kubectl cp -n <ns> "<app>-recovery-reader:/mnt/<path>" ./<file>
```

For SQLite, copy all three files (`<db>`, `<db>-shm`, `<db>-wal`) and make sure that each one arrived with
the expected size. A copy that lacks its WAL reads as an older, smaller database. It can also report
`database disk image is malformed`. Do not suppress `kubectl cp` errors, because that hides this fault.

### 4. Clean up

```bash
kubectl delete pod -n <ns> <app>-recovery-reader --wait=false
just kube delete-ks <ns> <app>-recovery
```

Then delete `recovery/` and remove the Kustomization document from `ks.yaml` (keep the leading
`---` on the first remaining document). You commit nothing here. Resume the root
(`just kube resume-ks flux-system flux-system`) after `delete-ks` finishes.

---

## Full restore (replaces the live PVC)

Use this only when you must replace the contents of the live claim. Use the recipe:

```bash
just kube restore-pvc <ns> <app> [offset]
```

`offset` 0 is the latest snapshot, 1 the previous, and so on. The recipe suspends the Kustomization
and HelmRelease that are both named `<app>` in `<ns>`, scales the workload to 0, and waits for the pods to go.
It then runs `kopiur restore --from-policy <app> --to-pvc <app> --wait`, resumes, force-reconciles and
waits for the rollout. It assumes that the Kustomization, HelmRelease, SnapshotPolicy and PVC all share
the app's name. On failure it leaves the app at 0 replicas with Flux suspended on purpose. Resume by
hand when you know the cause. Afterwards, check the app's own API or logs, not only pod readiness.

## After any restore into a database-backed app

Apps cache configuration at boot. If you restore or load data underneath a running app, restart
it. Otherwise it keeps serving the state it read at startup. Sonarr and Radarr report _"No indexers
available"_ with indexers in the database, and bazarr loses its language profile. Running
`kubectl rollout restart deployment/<app> -n <ns>` is part of the job.

Verify row counts per table, not the exit code. A load can report success and still be wrong.

## Common issues

- Restore stuck `Pending` with `MissingCredentialsSecret`: `credentialProjection` is set but the
  namespace already has the secret. Remove the field. See § Credentials.
- Snapshot stuck with the `snapshot-cleanup` finalizer:
  `kubectl patch snapshot <name> -n <ns> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'`
- Mover pod `Init:0/1` with FailedMount: another pod still mounts the volume. Scale to 0 first.
- Restore stuck Pending: make sure that the source snapshot is `Succeeded`, not `Failed`.
- Restore `Failed`, `kopiaErrorClass: Locked`, `mkdir /repository/...: read-only file system`
  in `.status.failure`: kopia tried to auto-compact the repository mid-restore, and restore
  movers mount it read-only. The fault is intermittent and the snapshot is fine. A `Failed` Restore is
  terminal. Run `just kube delete-ks <ns> <app>-recovery`, then `apply-ks` again. A retry completed
  on 2026-10-15.
- Recovered data vanishes when the Restore completes: you used `target.pvc` instead of
  `target.pvcRef`. Kubernetes garbage-collected the owned PVC.
