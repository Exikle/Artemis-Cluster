# Checklist: app/helmrelease.yaml

Mark each item **PASS**, **FAIL**, or **N/A**.

## Structure & schema

| # | Check | Result |
| --- | --- | --- |
| H1 | Schema comment present: `# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json` | |
| H2 | `apiVersion: helm.toolkit.fluxcd.io/v2` | |
| H3 | `chartRef.kind: OCIRepository`, `chartRef.name: <app>` (references own OCIRepository) | |
| H4 | `interval: 1h` | |
| H5 | `spec` field order: `chartRef → interval → dependsOn → install → upgrade → values` | |

## spec.values ordering

| # | Check | Result |
| --- | --- | --- |
| H6 | `defaultPodOptions` is the first key in `spec.values` (if present) | |
| H7 | All other `spec.values` keys are alphabetical after `defaultPodOptions` | |

## defaultPodOptions

| # | Check | Result |
| --- | --- | --- |
| H8 | `securityContext.runAsNonRoot: true` | |
| H9 | `securityContext.runAsUser: 1000` | |
| H10 | `securityContext.runAsGroup: 1000` | |
| H11 | `securityContext.fsGroup: 1000` present when app uses a PVC | |
| H12 | `securityContext.fsGroupChangePolicy: OnRootMismatch` | |

## Controllers

| # | Check | Result |
| --- | --- | --- |
| H13 | Controller has annotation `reloader.stakater.com/auto: "true"` | |
| H14 | Controller field order: `type → annotations → labels → <controller-specific> → pod → initContainers → containers` | |

## Containers

| # | Check | Result |
| --- | --- | --- |
| H15 | `image` is the first field in every container block | |
| H16 | `env.TZ` is NOT set — timezone injection is handled cluster-wide by k8tz (always N/A) | |
| H17 | `probes.liveness.enabled` is present | |
| H18 | `probes.readiness.enabled` is present | |
| H19 | `resources.requests` present (`cpu` and `memory`) | |
| H20 | `resources.limits.memory` present | |
| H21 | `resources.requests` comes before `resources.limits` | |
| H22 | `securityContext.allowPrivilegeEscalation: false` | |
| H23 | `securityContext.readOnlyRootFilesystem: true` | |
| H24 | `securityContext.capabilities.drop: [ALL]` | |
| H25 | Container field order: `image` first, then alphabetical | |

## Persistence

| # | Check | Result |
| --- | --- | --- |
| H26 | If VolSync used: `existingClaim: <app>` (not inline PVC spec) | |
| H27 | If `readOnlyRootFilesystem: true`: a `tmp` emptyDir mount exists | |
| H27a | Every emptyDir uses `advancedMounts` (never `globalMounts`), with a `subPath` per path — even for a single path | |
| H28 | Persistence item field order: `type → annotations → labels → <alphabetical> → globalMounts → advancedMounts` | |

## Service

| # | Check | Result |
| --- | --- | --- |
| H29 | Service item field order: `type → annotations → labels → <alphabetical>` | |

## Route

| # | Check | Result |
| --- | --- | --- |
| H30 | If route present: `parentRefs` references `internal-gateway` or `external-gateway` in `namespace: network` | |
| H31 | Route defined under `route.app:` in values — not a standalone HTTPRoute file | |
