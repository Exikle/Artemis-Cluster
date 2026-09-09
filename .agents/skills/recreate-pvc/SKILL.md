---
name: recreate-pvc
description: Delete and recreate an app's PVC so it comes back on current StorageClass parameters, restoring its data from kopiur. Use for "recreate the PVC", "migrate a volume to the new storage class", "restore this app from backup", "the PVC is on the old settings", "reprovision X's volume", or after a StorageClass parameter change that only takes effect on newly provisioned volumes. Scoped to the Artemis cluster.
---

# Skill: Recreate a PVC (and restore it from kopiur)

Delete an app's PVC and let it be recreated, so the new volume picks up current
StorageClass parameters. Data comes back through the kopiur volume populator.

> Read `.agents/references/kopiur.md` and `.agents/references/storage.md` first.

**StorageClass parameters are baked in at provision time.** Changing the class does
nothing to existing volumes — recreating the PVC is the only way they pick it up.

## Step 0 — Establish the restore path FIRST

Deleting a PVC destroys the volume: `miroir` has `reclaimPolicy: Delete`, so the old
PV is gone the moment the PVC is. There is no undo.

```bash
kubectl get pvc -n <ns> <app> -o jsonpath='{.spec.dataSourceRef.kind}/{.spec.dataSourceRef.name}{"\n"}'
```

- `Restore/<app>` → kopiur populator will restore it. Continue.
- empty → **no restore path.** Deleting loses the data permanently. Only proceed for a
  cache that rebuilds itself, or with the user's explicit acceptance of the loss.

Then confirm a snapshot exists AND is recent:

```bash
kopiur snapshots list -n <ns> | grep '^<app>-' | grep Succeeded | head -5
```

**`Succeeded` does NOT mean restorable** — see Gotchas. Check the age too: the populator's
`policy.onMissingSnapshot: Continue` means a missing snapshot yields a silently EMPTY
volume rather than an error.

## Step 1 — Stop whatever will fight the scale-down

Scaling to 0 does not stick on its own. Find what owns the replica count:

```bash
kubectl get <deploy|sts> -n <ns> <app> -o jsonpath='{.metadata.ownerReferences}'
```

| Owner                                                      | What to pause                             |
| ---------------------------------------------------------- | ----------------------------------------- |
| none (chart resource)                                      | `flux suspend helmrelease -n <ns> <app>`  |
| an operator CR (`InferenceService`, `PocketIDInstance`, …) | scale the **operator** to 0, then the app |

`flux suspend kustomization` is NOT enough for a chart-rendered workload — helm-controller
restores replicas. Conversely, app-template's `replicas: null` means Flux will _not_ put
replicas back after a failure, so you must scale up by hand.

## Step 2 — Scale down and confirm the volume is released

```bash
kubectl scale <deploy|sts> -n <ns> <app> --replicas=0
kubectl get pods -n <ns> -o jsonpath="{range .items[?(@.spec.volumes[*].persistentVolumeClaim.claimName=='<pvc>')]}{.metadata.name}{'\n'}{end}"
```

Wait for that to return nothing. A pod stuck `Terminating` holds the volume forever —
force it: `kubectl delete pod -n <ns> <pod> --force --grace-period=0`.

## Step 3 — Delete the PVC

`guard-destructive.sh` blocks `kubectl delete ... pvc`. A planned recreation with a
verified snapshot opts out of that one rule with the marker:

```bash
kubectl delete pvc -n <ns> <pvc> --wait=false  # I_HAVE_A_KOPIUR_SNAPSHOT
```

The marker disables ONLY `kubectl-delete-critical`. Every other rule still applies.
Do not use it without having done Step 0.

Wait for it to actually be gone before continuing — see the Terminating gotcha below.

## Step 4 — Recreate it

Which controller recreates the PVC depends on where it is defined:

| PVC comes from                                                    | Recreate with                                                                      |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `components/kopiur/backup` (has `dataSourceRef`)                  | `flux reconcile kustomization -n <ns> <ks>`                                        |
| app-template `persistence.<name>` (Helm)                          | `flux resume helmrelease …` then `flux reconcile helmrelease -n <ns> <hr> --force` |
| StatefulSet `volumeClaimTemplates` (name ends `-<sts>-<ordinal>`) | just scale the STS back up                                                         |

Helm will **not** recreate a resource deleted behind its back on a no-op upgrade — the
`--force` is what makes it reinstate the PVC.

Then scale back to the ORIGINAL replica count (capture it before Step 2; do not assume 1).

## Step 5 — Verify

```bash
kubectl get pvc -n <ns> <pvc>                     # Bound, and a NEW volume name
kubectl get restore -n <ns> <app> -o jsonpath='{.status.phase}{"\n"}'   # Completed
kubectl exec -n <ns> <pod> -- ls -la <mountPath>  # real files, not an empty dir
```

Confirm the new volume actually carries the current parameters:

```bash
AGENT=$(kubectl get pods -n miroir-system -o json | jq -r '.items[] | select(.spec.nodeName=="talos-cp-01") | select(.metadata.name|startswith("miroir-agent")) | .metadata.name')
kubectl exec -n miroir-system "$AGENT" -c agent -- drbdsetup show <pv-name> | grep -E 'quorum|on-no-quorum'
```

A `last-man-standing` volume prints **no** `on-no-quorum` line. One still on `freeze`
prints `on-no-quorum io-error`.

## After the restore — check for state that did NOT roll back

The PVC comes back at a point in time; anything the app keeps **outside** it does not.
An app whose metadata lives in the shared Postgres (`database` namespace) will have a
current database pointing at a restored-and-therefore-older volume, and the gap between
them is real drift.

`fediverse/apoci` is the visible case: its blob store is the PVC, its manifests are rows
in Postgres, and its GC reports the mismatch as
`gc: drift reconcile: file missing, no peer holds it`. On 2026-09-09 a ~30-minute restore
gap left 6 blobs referenced by the database and absent from disk.

Other apps split the same way and fail more quietly. After restoring one, ask what it
stores elsewhere, and check that first rather than waiting for it to surface.

If the dangling rows are for superseded artifacts, apoci's own retention clears them
(`gc.retention.perRepo` — `keepLastN: 7`, `maxAge: 24h` for the artemis-cluster repo).
To clear immediately, delete the affected `package_versions` and their `package_files`,
`package_tags` and orphaned `blobs` rows in one transaction — but first confirm the live
tag (`main`) is not among them and that `peer_blobs` holds no copy, and dump the rows to
a file so the edit is reversible.

## Gotchas

- **`Succeeded` is not `restorable`.** On 2026-09-09 several snapshots restored with
  `content <id> not found: object not found` despite being marked Succeeded. If offset 0
  fails, retry from an older one — frigate needed offset 12, matter-server offset 14.
- **A `Failed` Restore is terminal and never retries.** Patching it does nothing. Delete
  the Restore CR and let Flux recreate it, or apply one with a different
  `source.fromPolicy.offset` (suspend the Kustomization first, or Flux resets it to 0).
- **The populator pod can hang.** `<app>-populate-*` running many minutes with no log
  progress is stuck, not slow — delete the pod and the Job spawns a replacement.
- **Do not treat `<app>-populate-*` as the app's own pod** in readiness checks; the name
  prefix matches. Require the PVC to be `Bound` as well.
- **PVC stuck `Terminating`** is the `pvc-protection` finalizer: some pod still references
  it, including `Succeeded` ones. Delete that pod.
- **Reconciling while the PVC is still `Terminating`** makes Flux see it as present and
  skip recreation. Wait for it to disappear, then reconcile.
- **Deleting a PVC whose workload is intentionally at 0 replicas** just prunes the volume;
  the PVC returns `Pending` (`WaitForFirstConsumer`) and restores whenever it is next
  scheduled. This is the right way to retire a volume without losing its backup.
- **Do not remove `replicas: 0` in the same commit that prunes an app.** Flux can apply the
  HelmRelease change before it gets to the prune, so the app briefly scales up — which on a
  kopiur-backed PVC starts a full restore of data you were retiring. Seen with `arcade/eco`
  on 2026-09-09: it was `Pending` on a 16Gi restore before the prune caught up. Either split
  the two changes across commits, or `flux reconcile kustomization -n flux-system artemis-cluster`
  straight after pushing to close the window.
- **A guard false positive:** the rule matches the word `pvc` anywhere, so deleting a
  _MiroirVolume_ named `pvc-…` is blocked too. Same marker applies.
