---
name: recreate-pvc
description: Delete and recreate an app's PVC so it comes back on current StorageClass parameters, restoring its data from kopiur on the way. Use for "recreate the PVC", "migrate a volume to the new storage class", "the PVC is on the old settings", "reprovision X's volume", or after a StorageClass parameter change that only takes effect on newly provisioned volumes. The volume's settings are the reason here. For plain data loss or corruption with the PVC otherwise fine, use `kopiur-restore` instead. Scoped to the Artemis cluster.
compatibility: Destroys and reprovisions a live PVC. Requires a verified kopiur snapshot first, and the `I_HAVE_A_KOPIUR_SNAPSHOT` marker to pass the destructive-command guard.
---

# Skill: Recreate a PVC (and restore it from kopiur)

Delete an app's PVC and let it be recreated, so the new volume picks up current
StorageClass parameters. Data comes back through the kopiur volume populator.

> Read `.agents/references/kopiur.md` and `.agents/references/storage.md` first.

StorageClass parameters are set when the volume is provisioned. A change to the class does
nothing to existing volumes. The only way they pick it up is to recreate the PVC.

## Step 0: Establish the restore path FIRST

When you delete a PVC, you destroy the volume. `miroir` has `reclaimPolicy: Delete`, so the old
PV is gone when the PVC is gone. You cannot undo this.

```bash
kubectl get pvc -n <ns> <app> -o jsonpath='{.spec.dataSourceRef.kind}/{.spec.dataSourceRef.name}{"\n"}'
```

- `Restore/<app>`: the kopiur populator will restore it. Continue.
- Empty: there is no restore path. If you delete the PVC, the data is lost permanently. Continue only for a
  cache that rebuilds itself, or with the explicit acceptance of the user for the loss.

Then make sure that a snapshot exists AND is recent:

```bash
kopiur snapshots list -n <ns> | grep '^<app>-' | grep Succeeded | head -5
```

`Succeeded` does NOT mean restorable. See Gotchas. Check the age too. The populator has
`policy.onMissingSnapshot: Continue`, so a missing snapshot gives a silently EMPTY
volume, not an error.

## Step 1: Stop whatever will fight the scale-down

Scaling to 0 does not stay by itself. Find what owns the replica count:

```bash
kubectl get <deploy|sts> -n <ns> <app> -o jsonpath='{.metadata.ownerReferences}'
```

| Owner                                                      | What to pause                             |
| ---------------------------------------------------------- | ----------------------------------------- |
| none (chart resource)                                      | `flux suspend helmrelease -n <ns> <app>`  |
| an operator CR (`InferenceService`, `PocketIDInstance`, …) | scale the **operator** to 0, then the app |

`flux suspend kustomization` is NOT enough for a chart-rendered workload, because helm-controller
restores replicas. Also, app-template's `replicas: null` means that Flux will _not_ put
replicas back after a failure, so you must scale up by hand.

## Step 2: Scale down and confirm the volume is released

```bash
kubectl scale <deploy|sts> -n <ns> <app> --replicas=0
kubectl get pods -n <ns> -o jsonpath="{range .items[?(@.spec.volumes[*].persistentVolumeClaim.claimName=='<pvc>')]}{.metadata.name}{'\n'}{end}"
```

Wait for that command to return nothing. A pod stuck `Terminating` holds the volume forever.
Force it: `kubectl delete pod -n <ns> <pod> --force --grace-period=0`.

## Step 3: Delete the PVC

`guard-destructive.sh` blocks `kubectl delete ... pvc`. For a planned recreation with a
verified snapshot, opt out of that one rule with the marker:

```bash
kubectl delete pvc -n <ns> <pvc> --wait=false  # I_HAVE_A_KOPIUR_SNAPSHOT
```

The marker disables ONLY `kubectl-delete-critical`. Every other rule still applies.
Do not use the marker unless you did Step 0.

Wait until the PVC is gone before you continue. See the Terminating gotcha below.

## Step 4: Recreate it

The controller that recreates the PVC depends on where the PVC is defined:

| PVC comes from                                                    | Recreate with                                                                      |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `components/kopiur/backup` (has `dataSourceRef`)                  | `flux reconcile kustomization -n <ns> <ks>`                                        |
| app-template `persistence.<name>` (Helm)                          | `flux resume helmrelease …` then `flux reconcile helmrelease -n <ns> <hr> --force` |
| StatefulSet `volumeClaimTemplates` (name ends `-<sts>-<ordinal>`) | just scale the STS back up                                                         |

Helm does not recreate a resource that someone deleted behind its back on a no-op upgrade.
The `--force` makes it reinstate the PVC.

Then scale back to the ORIGINAL replica count. Capture it before Step 2, and do not assume 1.

## Step 5: Verify

```bash
kubectl get pvc -n <ns> <pvc>                     # Bound, and a NEW volume name
kubectl get restore -n <ns> <app> -o jsonpath='{.status.phase}{"\n"}'   # Completed
kubectl exec -n <ns> <pod> -- ls -la <mountPath>  # real files, not an empty dir
```

Make sure that the new volume carries the current parameters:

```bash
AGENT=$(kubectl get pods -n miroir-system -o json | jq -r '.items[] | select(.spec.nodeName=="talos-cp-01") | select(.metadata.name|startswith("miroir-agent")) | .metadata.name')
kubectl exec -n miroir-system "$AGENT" -c agent -- drbdsetup show <pv-name> | grep -E 'quorum|on-no-quorum'
```

A `last-man-standing` volume prints **no** `on-no-quorum` line. A volume that is still on `freeze`
prints `on-no-quorum io-error`.

## After the restore: check for state that did NOT roll back

The PVC comes back at a point in time. Anything the app keeps outside the PVC does not roll back.
An app whose metadata lives in the shared Postgres (`database` namespace) has a
current database that points at a restored, and therefore older, volume. The gap between
them is real drift.

`fediverse/apoci` is the visible case. Its blob store is the PVC, its manifests are rows
in Postgres, and its GC reports the mismatch as
`gc: drift reconcile: file missing, no peer holds it`. On 2026-09-09 a restore gap of about 30 minutes
left 6 blobs that the database referenced and that were absent from disk.

Other apps split the same way and fail more quietly. After you restore one, ask what it
stores elsewhere, and check that first. Do not wait for the fault to surface.

If the dangling rows are for superseded artifacts, the apoci retention clears them
(`gc.retention.perRepo`: `keepLastN: 7`, `maxAge: 24h` for the artemis-cluster repo).
To clear them immediately, delete the affected `package_versions` and their `package_files`,
`package_tags` and orphaned `blobs` rows in one transaction. First make sure that the live
tag (`main`) is not among them and that `peer_blobs` holds no copy. Dump the rows to
a file so that you can reverse the edit.

## Gotchas

- `Succeeded` is not `restorable`. On 2026-09-09 several snapshots restored with
  `content <id> not found: object not found` although they were marked Succeeded. If offset 0
  fails, retry from an older one. Frigate needed offset 12, matter-server offset 14.
- A `Failed` Restore is terminal and never retries. Patching it does nothing. Delete
  the Restore CR and let Flux recreate it, or apply one with a different
  `source.fromPolicy.offset` (suspend the Kustomization first, or Flux resets it to 0).
- The populator pod can hang. If `<app>-populate-*` runs for many minutes with no log
  progress, it is stuck, not slow. Delete the pod and the Job creates a replacement.
- Do not treat `<app>-populate-*` as the app's own pod in readiness checks, because the name
  prefix matches. Also require the PVC to be `Bound`.
- A PVC stuck `Terminating` is the `pvc-protection` finalizer: some pod still references
  it, including `Succeeded` pods. Delete that pod.
- If you reconcile while the PVC is still `Terminating`, Flux sees it as present and
  skips recreation. Wait for it to disappear, then reconcile.
- If you delete a PVC whose workload is intentionally at 0 replicas, the delete only prunes the volume.
  The PVC returns `Pending` (`WaitForFirstConsumer`) and restores when it is next
  scheduled. This is the right way to retire a volume without losing its backup.
- Do not remove `replicas: 0` in the same commit that prunes an app. Flux can apply the
  HelmRelease change before it gets to the prune, so the app briefly scales up. On a
  kopiur-backed PVC, this starts a full restore of data you were retiring. This happened with `arcade/eco`
  on 2026-09-09: it was `Pending` on a 16Gi restore before the prune caught up. Either split
  the two changes across commits, or run `flux reconcile kustomization -n flux-system flux-system`
  straight after you push, to close the window.
- A guard false positive: the rule matches the word `pvc` anywhere, so it also blocks the deletion of a
  _MiroirVolume_ named `pvc-…`. The same marker applies.
