# Checklist: app/helmrelease.yaml

Mark each item **PASS**, **FAIL**, or **N/A**.

## Structure & schema

| #   | Check                                                                                                                                                                                  | Result |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| H1  | Schema comment present: `# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json`                                           |        |
| H2  | `apiVersion: helm.toolkit.fluxcd.io/v2`                                                                                                                                                |        |
| H3  | `chartRef.kind: OCIRepository`, `chartRef.name: <app>` (references own OCIRepository)                                                                                                  |        |
| H4  | `interval: 1h`                                                                                                                                                                         |        |
| H5  | `spec` field order: `chartRef → interval → dependsOn → install → upgrade → values → postRenderers` — `postRenderers` last, and it is easy to miss because only a couple of apps use it |        |

## spec.values ordering

| #   | Check                                                                   | Result |
| --- | ----------------------------------------------------------------------- | ------ |
| H6  | `defaultPodOptions` is the first key in `spec.values` (if present)      |        |
| H7  | All other `spec.values` keys are alphabetical after `defaultPodOptions` |        |

## defaultPodOptions

> **PUID/PGID exception**: if the container has `PUID`/`PGID` env vars, the image is Linuxserver-style and starts as root to create its own user. Mark H8/H9/H10 as N/A and do NOT set `runAsNonRoot`, `runAsUser`, or `runAsGroup` — the entrypoint handles user switching. See advisory A19.

| #   | Check                                                                       | Result |
| --- | --------------------------------------------------------------------------- | ------ |
| H8  | `securityContext.runAsNonRoot: true` (N/A for PUID/PGID images — see above) |        |
| H9  | `securityContext.runAsUser: 1000` (N/A for PUID/PGID images — see above)    |        |
| H10 | `securityContext.runAsGroup: 1000` (N/A for PUID/PGID images — see above)   |        |
| H11 | `securityContext.fsGroup: 1000` present when app uses a PVC                 |        |
| H12 | `securityContext.fsGroupChangePolicy: OnRootMismatch`                       |        |

## Controllers

| #   | Check                                                                                                                                                                | Result |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| H13 | Controller has annotation `reloader.stakater.com/auto: "true"`                                                                                                       |        |
| H14 | Controller field order: `enabled → type → annotations → labels → <controller-specific> → pod → initContainers → containers` — `enabled` is FIRST wherever it appears |        |

## Containers

| #   | Check                                                                                                                  | Result |
| --- | ---------------------------------------------------------------------------------------------------------------------- | ------ |
| H15 | `image` is the first field in every container block                                                                    |        |
| H16 | `env.TZ` is NOT set — timezone injection is handled cluster-wide by k8tz (always N/A)                                  |        |
| H17 | `probes.liveness.enabled` is present                                                                                   |        |
| H18 | `probes.readiness.enabled` is present                                                                                  |        |
| H19 | `resources.requests` present (`cpu` and `memory`)                                                                      |        |
| H20 | `resources.limits.memory` present                                                                                      |        |
| H21 | `resources.requests` comes before `resources.limits`                                                                   |        |
| H22 | `securityContext.allowPrivilegeEscalation: false` (N/A for PUID/PGID images)                                           |        |
| H23 | `securityContext.readOnlyRootFilesystem: true` (N/A for PUID/PGID images and Chrome/Chromium-based apps — see A19/A20) |        |
| H24 | `securityContext.capabilities.drop: [ALL]` (N/A for PUID/PGID images)                                                  |        |
| H25 | Container field order: `image` first, then alphabetical                                                                |        |

## Persistence

| #    | Check                                                                                                           | Result |
| ---- | --------------------------------------------------------------------------------------------------------------- | ------ |
| H26  | If kopiur used: `existingClaim: <app>` (not inline PVC spec)                                                    |        |
| H27  | If `readOnlyRootFilesystem: true`: a `tmp` emptyDir mount exists                                                |        |
| H27a | Every emptyDir uses `advancedMounts` (never `globalMounts`), with a `subPath` per path — even for a single path |        |
| H28  | Persistence item field order: `type → annotations → labels → <alphabetical> → globalMounts → advancedMounts`    |        |

## Service

| #   | Check                                                                                                                | Result |
| --- | -------------------------------------------------------------------------------------------------------------------- | ------ |
| H29 | Service item field order: `type → annotations → labels → <alphabetical> → ports` — `ports` is LAST, not alphabetical |        |

## Route

| #   | Check                                                                                                                                                                                                                                                                                                                                                                  | Result |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| H30 | If route present: `parentRefs` references `internal-gateway` (LAN-only) **or `edge-gateway`** (public), always with `namespace: network`. A new route on `external-gateway` is a FAIL — legacy, no upstream                                                                                                                                                            |        |
| H31 | Route defined under `route.app:` in values — not a standalone HTTPRoute file                                                                                                                                                                                                                                                                                           |        |
| H32 | Hostname/listener match: `*.frostlink.dev` only on `edge-gateway` (`sectionName: https` or none); `*.dcunha.io` on `internal-gateway` or on `edge-gateway` with `sectionName: https-dcunha` or none; apex `dcunha.io` on `edge-gateway` with `https-dcunha-apex`. A `*.dcunha.io` route on `edge-gateway` pinned to `sectionName: https` is a FAIL — it never attaches |        |

### Gateways

| Gateway            | Namespace | Serves                                        | Exposure                                           |
| ------------------ | --------- | --------------------------------------------- | -------------------------------------------------- |
| `internal-gateway` | `network` | `*.dcunha.io`                                 | LoadBalancer `10.10.99.98`, LAN only               |
| `edge-gateway`     | `network` | `*.frostlink.dev`, `*.dcunha.io`, `dcunha.io` | LoadBalancer `10.10.99.90`, public via towonel     |
| `external-gateway` | `network` | nothing                                       | LoadBalancer `10.10.99.97`, legacy — no new routes |

`edge-gateway` has three HTTPS listeners: `https` (`frostlink-dev-tls`), `https-dcunha` and
`https-dcunha-apex` (`dcunha-io-tls`), plus an `http` listener that only carries the shared
`https-redirect` — app routes never attach to it. An app can carry two routes for two hostnames: `media/jellyfin` has a
`route.app` (`jellyfin.dcunha.io`) and a `route.frostlink` (`jellyfin.frostlink.dev`), both on
`edge-gateway`. Details: `.agents/references/towonel-agent.md` § Which gateway to attach a route
to, which wins over this table.
