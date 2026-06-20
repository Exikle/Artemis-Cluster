# Skill: Kopiur PVC Migrate

Migrate a PVC from one StorageClass to another (e.g. local-path → openebs-zfs) on Frostlink using kopiur snapshots and Restore, without data loss.

## Critical Rules

- **Always patch PV reclaim policy to Retain first** — before deleting anything, so data survives PVC deletion.
- **Always use `target.pvcRef`** — pre-create the destination PVC, then Restore writes into it without taking ownership. `target.pvc` creates an OWNED PVC that gets deleted when the Restore is GC'd.
- **Don't resume the kustomization until Restore completes** — starting the app while the Restore mover has the PVC mounted (RWO) will block the mover.
- **Postgres data dir (mode 700, uid 999)** cannot be read by copyMethod: Direct or an unprivileged kopiur mover. Use a privileged `cp -a` Job instead of kopiur for the postgres PVC — see the postgres section below.
- **openebs-zfs WaitForFirstConsumer** — the destination PVC stays Pending until something mounts it. The Restore mover pod counts.
- **`helm.sh/resource-policy: keep`** — add this annotation to Helm-managed PVCs before migrating, or Helm will recreate them on openebs-zfs on the next upgrade (then delete your live PVC when you switch to `existingClaim`).

## When to Use This vs. Kopiur Restore

This skill is for **StorageClass migrations** where data must survive the transition. The kopiur-restore skill is for **restoring from backup** after data loss or corruption.

---

## Standard PVC Migration (non-postgres)

### Step 1 — Take a Pre-Migration Snapshot

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig apply -f - <<'EOF'
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Snapshot
metadata:
  name: <app>-premigration
  namespace: <namespace>
spec:
  policyRef:
    name: <app>
EOF
```

Wait for it to succeed:

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get snapshot <app>-premigration -n <namespace> -w
```

### Step 2 — Suspend Kustomization and Scale to 0

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig patch kustomization <ks-name> \
  -n fediverse --type=merge -p '{"spec":{"suspend":true}}'
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig scale deployment/<app> -n <namespace> --replicas=0
```

### Step 3 — Protect the Old PV and Delete the Old PVC

```bash
# Get PV name
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get pvc <pvc-name> -n <namespace> \
  -o jsonpath='{.spec.volumeName}'

# Patch to Retain
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig patch pv <pv-name> \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

# Delete old PVC
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig delete pvc <pvc-name> -n <namespace>
```

If stuck Terminating (pvc-protection finalizer), delete the completed mover pod holding it.

### Step 4 — Create the Destination PVC

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <pvc-name>
  namespace: <namespace>
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: <capacity>
  storageClassName: openebs-zfs
EOF
```

### Step 5 — Create the Restore

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig apply -f - <<'EOF'
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Restore
metadata:
  name: <app>-migration
  namespace: <namespace>
spec:
  credentialProjection:
    enabled: true
  source:
    snapshotRef:
      name: <app>-premigration
  target:
    pvcRef:
      name: <pvc-name>
EOF
```

Monitor until Succeeded:

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get restore <app>-migration -n <namespace> -w
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get pods -n <namespace>
```

### Step 6 — Update HelmRelease to existingClaim

In the HelmRelease values, switch from size-based persistence to `existingClaim`:

```yaml
persistence:
    data:
        existingClaim: <pvc-name>
```

Also add `helm.sh/resource-policy: keep` annotation to the PVC to prevent Helm from deleting it on future upgrades:

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig annotate pvc <pvc-name> \
  -n <namespace> helm.sh/resource-policy=keep
```

### Step 7 — Resume and Verify

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig patch kustomization <ks-name> \
  -n fediverse --type=merge -p '{"spec":{"suspend":false}}'
```

Confirm app comes up and data is present.

### Step 8 — Clean Up

```bash
# Delete Restore and Snapshot objects
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig delete restore <app>-migration -n <namespace>
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig delete snapshot <app>-premigration -n <namespace>

# Delete orphan kopia cache PVC if present
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get pvc -n <namespace> | grep kopia-cache

# Delete old PV (data now on openebs-zfs)
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig delete pv <old-pv-name>
```

---

## Postgres PVC Migration (uid 999, mode 700)

kopiur cannot read the postgres data directory (`mode 700, uid 999`) with `copyMethod: Direct`. Use a privileged Job instead.

### Steps 1–3: Same as above (snapshot, suspend, protect old PV)

### Step 4 — Create NEW destination PVC with a temporary name

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <pvc-name>-new
  namespace: <namespace>
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: <capacity>
  storageClassName: openebs-zfs
EOF
```

### Step 5 — Run a Privileged Copy Job

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: <app>-pgdata-copy
  namespace: <namespace>
spec:
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: 0
      containers:
        - name: copy
          image: docker.io/library/busybox:latest
          command:
            - sh
            - -c
            - cp -a /source/. /dest/ && echo Done
          volumeMounts:
            - name: source
              mountPath: /source
            - name: dest
              mountPath: /dest
      volumes:
        - name: source
          persistentVolumeClaim:
            claimName: <old-pvc-name>     # still bound to old Released PV
        - name: dest
          persistentVolumeClaim:
            claimName: <pvc-name>-new
EOF
```

Wait for `Complete`:

```bash
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig get job <app>-pgdata-copy -n <namespace>
```

### Step 6 — Rename: -new → final name

Scale app to 0, then:

```bash
# Delete new PVC and release PV from it
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig delete pvc <pvc-name>-new -n <namespace>
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig patch pv <new-pv-name> \
  --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'

# Recreate with final name pointing to same PV
kubectl --kubeconfig /home/exikle/frostlink/kubeconfig apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <pvc-name>
  namespace: <namespace>
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: <capacity>
  storageClassName: openebs-zfs
  volumeName: <new-pv-name>
EOF
```

### Steps 6–8: Same as standard migration (update HelmRelease, resume, clean up)

---

## Common Issues

- **Helm deletes PVC on upgrade** when switching to `existingClaim`: add `helm.sh/resource-policy: keep` annotation to PVC before committing the HelmRelease change
- **Flux reconcile overwrites live patch**: must commit HelmRelease changes and wait for new OCIRepository artifact — server-side apply is overwritten by Flux
- **Snapshot `disk quota exceeded`**: SnapshotPolicy missing `mover.cache.capacity: 2Gi` — add it before snapshotting
- **Kustomization namespace**: on Frostlink, kustomizations live in `fediverse` namespace, not `flux-system`
- **Snapshot deletion stuck**: remove `kopiur.home-operations.com/snapshot-cleanup` finalizer manually if cleanup job never starts
