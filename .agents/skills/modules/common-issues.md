# Module: Common Issues

## Runtime / pod failures

| Symptom                      | Cause                                           | Fix                                                                                        |
| ---------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Permission denied on startup | Image UID doesn't match `runAsUser: 1000`       | Temporarily set `runAsNonRoot: false` to identify required UID, then align securityContext |
| Crash on write to `/tmp`     | `readOnlyRootFilesystem: true` without emptyDir | Add `tmp` emptyDir persistence entry with `advancedMounts`                                 |
| Pod stuck in `Init`          | ExternalSecret not synced                       | See ExternalSecret section below                                                           |

## ExternalSecret not syncing

- Verify 1Password field names match **exactly** (case-sensitive) — a mismatch returns empty secret with no error.
- Run: `just kube sync-es` to force a refresh.
- Check: `kubectl describe externalsecret <app> -n <namespace>` for sync status.

## HelmRelease stuck / not progressing

```bash
# Suspend and reset
flux suspend hr <app> -n <namespace>
kubectl delete secret -n <namespace> -l owner=helm,name=<app>
flux resume hr <app> -n <namespace>
```

## OCIRepository not resolving

- Verify `url: oci://ghcr.io/bjw-s-labs/helm/app-template` (note: `-labs`, not `-bjw-s`).
- Verify `apiVersion: source.toolkit.fluxcd.io/v1` (not `v1beta2`).

## Probe endpoint reference

Check app docs — don't assume `/`:

| App type                        | Probe path                         |
| ------------------------------- | ---------------------------------- |
| Arr apps (Sonarr, Radarr, etc.) | `/ping`                            |
| Go apps                         | `/healthz`                         |
| Generic                         | `/health`                          |
| 1Password Connect               | `/heartbeat`                       |
| Unknown                         | Try `/ping`, `/health`, `/healthz` |

## readOnlyRootFilesystem without tmp emptyDir

App will crash writing to `/tmp`. Always pair `readOnlyRootFilesystem: true` with a `tmp` emptyDir.
Use `advancedMounts` with `subPath: tmp` — even for a single path — so future additions are easy.

## dependsOn without namespace field

Cross-namespace deps silently resolve to the local namespace if `namespace:` is omitted.
Always add `namespace:` explicitly on every cross-namespace `dependsOn` entry.

## VOLSYNC_CAPACITY in wrong place

`VOLSYNC_CAPACITY` must be in `ks.yaml` under `postBuild.substitute`, not in the app's `persistence` spec.
