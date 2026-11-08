# Module: Common Issues

## Runtime / pod failures

| Symptom                                                        | Cause                                           | Fix                                                                                                         |
| -------------------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Permission denied on startup                                   | Image UID does not match `runAsUser: 1000`      | Set `runAsNonRoot: false` for a short time to find the UID that the image needs. Then align securityContext |
| Crash on write to `/tmp`                                       | `readOnlyRootFilesystem: true` without emptyDir | Add `tmp` emptyDir persistence entry with `advancedMounts`                                                  |
| Pod stuck in `Init`                                            | ExternalSecret not synced                       | See ExternalSecret section below                                                                            |
| `OSError: [Errno 16] Device or resource busy` on `os.rename()` | App rewrites a file mounted from a ConfigMap    | See ConfigMap mount section below                                                                           |

## Writes to ConfigMap-mounted files fail

ConfigMap files are read-only bind mounts, so an in-place rewrite fails. `os.rename()`
returns `OSError: [Errno 16] Device or resource busy` and not a permissions error.
This sends you to securityContext instead of the mount.

Copy the file out before the app starts. Mount the ConfigMap at a staging path. Add an
initContainer that copies the file into an `emptyDir`. Point the app at the `emptyDir` copy.

## ExternalSecret not syncing

- Make sure that the 1Password field names match exactly (case-sensitive). A mismatch returns an empty secret with no error.
- To force a refresh, run `just kube sync-flux es`.
- To read the sync status, run `kubectl describe externalsecret <app> -n <namespace>`.

## HelmRelease stuck / not progressing

```bash
# Suspend and reset
flux suspend hr <app> -n <namespace>
kubectl delete secret -n <namespace> -l owner=helm,name=<app>
flux resume hr <app> -n <namespace>
```

`resume-ks` will not resume that HelmRelease. It resumes only the one Kustomization that you name,
and HelmReleases are not Kustomizations. Resume the HelmRelease by hand with `flux resume hr`.
`resume-ks` does list any Kustomizations that are still suspended in a warning on its last line.
Read that warning before you leave.

## OCIRepository not resolving

- Make sure that the URL is `url: oci://ghcr.io/bjw-s-labs/helm/app-template` (note: `-labs`, not `-bjw-s`).
- Make sure that the apiVersion is `apiVersion: source.toolkit.fluxcd.io/v1` (not `v1beta2`).

## Probe endpoint reference

Check the docs of the app. Do not assume `/`:

| App type                        | Probe path                                                                            |
| ------------------------------- | ------------------------------------------------------------------------------------- |
| Arr apps (Sonarr, Radarr, etc.) | `/ping`, but each arr has its own path. Check the app, do not assume                  |
| Go apps                         | `/healthz`                                                                            |
| 1Password Connect               | `/heartbeat`                                                                          |
| Anything else                   | No default. Try `/ping`, `/health`, `/healthz` and confirm against the app's own docs |

There is no cluster-wide "generic" probe path. `cluster-conventions.md` § Common Mistakes says
the same thing about the arr apps. A wrong probe path causes a crash loop. It is not a soft failure.

## readOnlyRootFilesystem without tmp emptyDir

The app will crash when it writes to `/tmp`. Always pair `readOnlyRootFilesystem: true` with a `tmp` emptyDir.
Use `advancedMounts` with `subPath: tmp`, even for a single path, so that later additions are easy.

## dependsOn without namespace field

If `namespace:` is missing, a cross-namespace dependency silently resolves to the local namespace.
Always add `namespace:` explicitly on every cross-namespace `dependsOn` entry.

## KOPIUR_CAPACITY in wrong place

`KOPIUR_CAPACITY` must be in `ks.yaml` under `postBuild.substitute`, not in the app's `persistence` spec.
The kopiur component reads it as `${KOPIUR_CAPACITY:=5Gi}`. The `VOLSYNC_*` variables are dead. VolSync
was removed 2026-08-01 and nothing consumes them.
