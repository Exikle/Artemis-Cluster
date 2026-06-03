# Checklist: Advisory

These are judgment-call recommendations — not hard convention violations. Mark each **RECOMMEND**, **SKIP** (not applicable), or **N/A** (can't determine without more context).

Findings go in the `### ADVISORY` section of the report, distinct from FAIL/WARN. **Never auto-fix advisory items — they require human review.**

---

## Storage & Data Layer

| #   | Check                                                                                                                                    |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | App supports SQLite but is configured with an external Postgres/CNPG — recommend SQLite if workload is single-writer and low-concurrency |
| A2  | App has a PVC but no VolSync component in `ks.yaml` — data not backed up; recommend adding VolSync                                       |
| A3  | `ceph-filesystem` used for a single-writer app — `ceph-block` (RBD) gives better performance for RWO workloads                           |
| A4  | App uses NFS for its own data store (not for shared media) — recommend Ceph PVC for reliability                                          |

---

## Reliability

| #   | Check                                                                                                                                                                     |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A5  | `resources.requests` or `resources.limits` missing — pod can starve neighbors or be OOM-killed without warning                                                            |
| A6  | Liveness and/or readiness probes not configured (`enabled: false` or absent) — Kubernetes cannot detect hangs or failed startups                                          |
| A6a | Probe paths are suboptimal — probes hitting `/` instead of a dedicated `/ping`, `/health`, or `/healthz` endpoint; noisy and may mask real failures                       |
| A7  | `retryInterval` absent from `ks.yaml` — slow recovery from transient failures; recommend `retryInterval: 1m`                                                              |
| A8  | `dependsOn` chain appears incomplete — check whether the app's actual dependencies (storage, secrets, CNPG) are listed                                                    |
| A14 | App uses static `replicas` but is a stateless web-facing workload — consider an HPA (`minReplicas`/`maxReplicas`) for traffic-driven scaling instead of a hardcoded count |

---

## Image Hygiene

| #   | Check                                                                                                                           |
| --- | ------------------------------------------------------------------------------------------------------------------------------- |
| A9  | Container image uses a mutable tag (`latest` or bare semver without SHA digest) — not reproducible; recommend `vX.Y.Z@sha256:…` |

---

## Security & Exposure

| #   | Check                                                                                                                                                                        |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A10 | App is on `external-gateway` (publicly reachable) but has no SecurityPolicy OIDC or equivalent auth — confirm intentional or recommend adding Pocket-ID OIDC                 |
| A11 | Secrets passed as environment variables where the app supports file-based secret mounts — env vars are visible in `kubectl describe pod`; recommend secretMount if supported |
| A17 | No AppArmor or Seccomp profile configured — consider `seccompProfile.type: RuntimeDefault` in `defaultPodOptions.securityContext` as a low-friction hardening baseline       |

---

## Observability

| #   | Check                                                                                                                                                                       |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A18 | App exposes a `/metrics` endpoint (check image docs or port list) but no ServiceMonitor is present — metrics are not scraped by kube-prometheus-stack; recommend adding one |

---

## Image Compatibility

| #   | Check                                                                                                                                                                                                      |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A19 | Image has `PUID`/`PGID` env vars (Linuxserver-style) — entrypoint starts as root to create its user. Skip H8/H9/H10/H22/H23/H24. Only `fsGroup` and `fsGroupChangePolicy` are safe in `defaultPodOptions`. |
| A20 | Image is Chrome/Chromium-based — Chrome writes to its profile dir at startup. Skip H23 (`readOnlyRootFilesystem`); it crashes even with a `/tmp` emptyDir present.                                         |

---

## Architecture

| #   | Check                                                                                                                                                                                    |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A12 | App has multiple logical components (e.g. app + database + worker) in a single HelmRelease — consider splitting into separate kustomizations for independent reconciliation and rollback |
| A13 | Multiple apps in the same namespace share a dependency (e.g. same CNPG cluster) — flag if this violates the silo pattern                                                                 |
| A15 | No `nodeSelector` or `affinity` rules — if the cluster has heterogeneous nodes (e.g. high-memory, GPU, or spot), consider pinning or preferring cheaper nodes for this workload          |
| A16 | App uses a `Deployment` controller but mounts a PVC and requires stable pod identity — consider `StatefulSet` (`type: statefulset` in app-template) if restart ordering matters          |
