# Checklist: Advisory

These are judgment-call recommendations. They are not hard convention violations. Mark each item RECOMMEND, SKIP (not applicable), or N/A (cannot be decided without more context).

Findings go in the `### ADVISORY` section of the report, separate from FAIL and WARN. Never auto-fix advisory items. A human must review them.

---

## Storage & Data Layer

| #   | Check                                                                                                                                                                                                                                                                                                                                      |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| A1  | The app's data store has no stated reason. Either choice is fine: shared CNPG, or SQLite for a single-writer, low-concurrency workload. The choice must be a decision, not a default. Flag only an unexplained per-app database, or an app moved onto Postgres with no rationale. Do not read this as "recommend migrating back to SQLite" |
| A2  | App has a PVC but no kopiur component in `ks.yaml`. The data is not backed up. Recommend adding kopiur                                                                                                                                                                                                                                     |
| A3  | A StorageClass other than `miroir` or `miroir-local` is named. Those two are the only StorageClasses that exist                                                                                                                                                                                                                            |
| A4  | App uses NFS for its own data store (not for shared media). Recommend a `miroir` PVC with `components/kopiur/backup`                                                                                                                                                                                                                       |

---

## Reliability

| #   | Check                                                                                                                                                                    |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| A5  | `resources.requests` or `resources.limits` missing. The pod can starve its neighbors or be OOM-killed without warning                                                    |
| A6  | Liveness and/or readiness probes not configured (`enabled: false` or absent). Kubernetes cannot detect hangs or failed startups                                          |
| A6a | Probe paths are suboptimal. The probes hit `/` and not a dedicated `/ping`, `/health`, or `/healthz` endpoint. This is noisy and can hide real failures                  |
| A7  | `retryInterval` absent from `ks.yaml`. Recovery from transient failures is slow. Recommend `retryInterval: 1m`                                                           |
| A8  | `dependsOn` chain appears incomplete. Make sure that the real dependencies of the app (storage, secrets, CNPG) are listed                                                |
| A14 | App uses static `replicas` but is a stateless web-facing workload. Consider an HPA (`minReplicas`/`maxReplicas`) for traffic-driven scaling instead of a hardcoded count |

---

## Image Hygiene

| #   | Check                                                                                                                                |
| --- | ------------------------------------------------------------------------------------------------------------------------------------ |
| A9  | Container image uses a mutable tag (`latest` or bare semver without SHA digest). It is not reproducible. Recommend `vX.Y.Z@sha256:…` |

---

## Security & Exposure

| #   | Check                                                                                                                                                                                                               |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A10 | App is on `edge-gateway` (publicly reachable) but has no SecurityPolicy OIDC or equivalent auth. Confirm that this is intentional, or recommend a gate: `components/tinyauth` (standard) or `components/envoy-oidc` |
| A11 | Secrets passed as environment variables where the app supports file-based secret mounts. Env vars are visible in `kubectl describe pod`. Recommend secretMount if the app supports it                               |
| A17 | No AppArmor or Seccomp profile is configured. Consider `seccompProfile.type: RuntimeDefault` in `defaultPodOptions.securityContext` as a low-friction hardening baseline                                            |

---

## Observability

| #   | Check                                                                                                                                                                                                                                                                                                                                                        |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| A18 | App exposes a `/metrics` endpoint (check the image docs or the port list) but no ServiceMonitor is present, so metrics are not scraped. This cluster has no kube-prometheus-stack. The stack is VictoriaMetrics à-la-carte (`observability/victoria/*`), and the VM operator converts `ServiceMonitor` and `VMNodeScrape`. Recommend adding a ServiceMonitor |

---

## Image Compatibility

| #   | Check                                                                                                                                                                                                         |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A19 | Image has `PUID`/`PGID` env vars (Linuxserver-style). The entrypoint starts as root to create its user. Skip H8/H9/H10/H22/H23/H24. Only `fsGroup` and `fsGroupChangePolicy` are safe in `defaultPodOptions`. |
| A20 | Image is Chrome/Chromium-based. Chrome writes to its profile directory at startup. Skip H23 (`readOnlyRootFilesystem`). The image crashes even when a `/tmp` emptyDir is present.                             |

---

## Architecture

| #   | Check                                                                                                                                                                                        |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A12 | App has multiple logical components (e.g. app + database + worker) in a single HelmRelease. Consider splitting them into separate kustomizations for independent reconciliation and rollback |
| A13 | App runs a dedicated Postgres or Redis instead of the shared `database` cluster. Flag it unless a documented reason says it cannot share                                                     |
| A15 | No `nodeSelector` or `affinity` rules. If the cluster has mixed nodes (for example high-memory, GPU, or spot), consider pinning this workload to cheaper nodes or preferring them            |
| A16 | App uses a `Deployment` controller but mounts a PVC and requires stable pod identity. Consider `StatefulSet` (`type: statefulset` in app-template) if restart order matters                  |
