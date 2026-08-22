# Module: Common Issues

## Runtime / pod failures

| Symptom                                                        | Cause                                           | Fix                                                                                        |
| -------------------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Permission denied on startup                                   | Image UID doesn't match `runAsUser: 1000`       | Temporarily set `runAsNonRoot: false` to identify required UID, then align securityContext |
| Crash on write to `/tmp`                                       | `readOnlyRootFilesystem: true` without emptyDir | Add `tmp` emptyDir persistence entry with `advancedMounts`                                 |
| Pod stuck in `Init`                                            | ExternalSecret not synced                       | See ExternalSecret section below                                                           |
| `OSError: [Errno 16] Device or resource busy` on `os.rename()` | App rewrites a file mounted from a ConfigMap    | See ConfigMap mount section below                                                          |

## Writes to ConfigMap-mounted files fail

ConfigMap files are read-only bind mounts, so an in-place rewrite fails — `os.rename()`
returns `OSError: [Errno 16] Device or resource busy` rather than a permissions error,
which sends you looking at securityContext instead of the mount.

Copy the file out before the app starts: mount the ConfigMap at a staging path, add an
initContainer that copies it into an `emptyDir`, and point the app at the `emptyDir` copy.

## ExternalSecret not syncing

- Verify 1Password field names match **exactly** (case-sensitive) — a mismatch returns empty secret with no error.
- Run: `just kube sync es` to force a refresh.
- Check: `kubectl describe externalsecret <app> -n <namespace>` for sync status.

## HelmRelease stuck / not progressing

```bash
# Suspend and reset
flux suspend hr <app> -n <namespace>
kubectl delete secret -n <namespace> -l owner=helm,name=<app>
flux resume hr <app> -n <namespace>
```

If you leave that HelmRelease suspended, `just kube resume-ks` at the end of the session picks it
up — it resumes whatever is suspended cluster-wide, not just what `apply-ks` suspended. That is
usually what you want; if it is not, un-suspend deliberately before running it.

## OCIRepository not resolving

- Verify `url: oci://ghcr.io/bjw-s-labs/helm/app-template` (note: `-labs`, not `-bjw-s`).
- Verify `apiVersion: source.toolkit.fluxcd.io/v1` (not `v1beta2`).

## Probe endpoint reference

Check app docs — don't assume `/`:

| App type                        | Probe path                                                                            |
| ------------------------------- | ------------------------------------------------------------------------------------- |
| Arr apps (Sonarr, Radarr, etc.) | `/ping` — but each arr has its own; check the app, don't assume                       |
| Go apps                         | `/healthz`                                                                            |
| 1Password Connect               | `/heartbeat`                                                                          |
| Anything else                   | No default. Try `/ping`, `/health`, `/healthz` and confirm against the app's own docs |

There is no cluster-wide "generic" probe path. `cluster-conventions.md` § Common Mistakes says
the same thing about the arr apps — a wrong probe path is a crash-loop, not a soft failure.

## readOnlyRootFilesystem without tmp emptyDir

App will crash writing to `/tmp`. Always pair `readOnlyRootFilesystem: true` with a `tmp` emptyDir.
Use `advancedMounts` with `subPath: tmp` — even for a single path — so future additions are easy.

## dependsOn without namespace field

Cross-namespace deps silently resolve to the local namespace if `namespace:` is omitted.
Always add `namespace:` explicitly on every cross-namespace `dependsOn` entry.

## KOPIUR_CAPACITY in wrong place

`KOPIUR_CAPACITY` must be in `ks.yaml` under `postBuild.substitute`, not in the app's `persistence` spec.
The kopiur component reads it as `${KOPIUR_CAPACITY:=5Gi}`. `VOLSYNC_*` variables are dead — VolSync
was removed 2026-08-01 and nothing consumes them.
