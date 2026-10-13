# Module: HelmRelease Template

The schema line is the one the hook writes for app-template; a non-app-template chart uses
`https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json`.

Field ordering is defined in `.agents/instructions/yaml-conventions.md`. `postRenderers` is last
and easy to forget; only a couple of apps use it (`.agents/references/observability.md`).

## Minimal template

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
    name: <app>
spec:
    chartRef:
        kind: OCIRepository
        name: <app>
    interval: 1h
    values:
        defaultPodOptions:
            securityContext:
                fsGroup: 1000
                fsGroupChangePolicy: OnRootMismatch
                runAsGroup: 1000
                runAsNonRoot: true
                runAsUser: 1000
        controllers:
            <app>:
                annotations:
                    reloader.stakater.com/auto: "true"
                containers:
                    app:
                        image:
                            repository: <image-repo>
                            tag: <tag>@sha256:<digest>
                        probes:
                            liveness:
                                enabled: true
                            readiness:
                                enabled: true
                            startup:
                                enabled: false
                        resources:
                            requests:
                                cpu: 10m
                                memory: 128Mi
                            limits:
                                memory: 512Mi
                        securityContext:
                            allowPrivilegeEscalation: false
                            capabilities:
                                drop:
                                    - ALL
                            readOnlyRootFilesystem: true
        persistence:
            data:
                existingClaim: <app>
                globalMounts:
                    - path: /data
            tmp:
                type: emptyDir
                advancedMounts:
                    <app>:
                        app:
                            - path: /tmp
                              subPath: tmp
        route:
            app:
                hostnames:
                    - <hostname>
                parentRefs:
                    - name: internal-gateway
                      namespace: network
        service:
            app:
                ports:
                    http:
                        port: <port>
```

## Gateways — pick by hostname suffix

| Gateway            | Hostnames                        | Exposure                                      |
| ------------------ | -------------------------------- | --------------------------------------------- |
| `internal-gateway` | `*.dcunha.io`                    | LAN only                                      |
| `edge-gateway`     | `*.frostlink.dev`, `*.dcunha.io` | Public via towonel (and LAN); `:80` redirects |
| `external-gateway` | —                                | Legacy, no routes — do not use                |

All three live in `namespace: network`. Every public app goes on `edge-gateway`, whichever
domain. A `*.dcunha.io` route there must not pin `sectionName: https` — that is the
`frostlink.dev` listener; use `https-dcunha` or omit it. An app can carry a second hostname by
adding a second named route:

```yaml
route:
    app:
        hostnames:
            - <app>.dcunha.io
        parentRefs:
            - name: edge-gateway
              namespace: network
    frostlink:
        hostnames:
            - <app>.frostlink.dev
        parentRefs:
            - name: edge-gateway
              namespace: network
```

Details, the listener table and the towonel origin mapping: `.agents/references/towonel-agent.md`
(wins over this table).

## Notes

- Do NOT add `namespace:` to metadata — the Flux Kustomization's `targetNamespace` injects it.
- `fsGroup: 1000` only needed when the app uses a PVC.
- `readOnlyRootFilesystem: true` requires a `tmp` emptyDir entry. Use `advancedMounts` with `subPath` — even for a single path.
- Remove `persistence` block entirely if the app has no PVC and no writable paths.
- Remove `route` block if no ingress is needed.
- Never set `TZ` env var — k8tz handles timezone injection cluster-wide.
- `reloader.stakater.com/auto: "true"` must be on the controller annotation, not the pod.
- `startup` probe: include with `enabled: false` to be explicit, or omit entirely.
- `ports` is the **last** key in a `service.<name>` entry, not alphabetical.
- `enabled` is the **first** key in any `controllers.<name>` entry that has it.
- No inline comments in the manifest you produce from this — the template's prose belongs in
  `.agents/references/`, per `yaml-conventions.md` § No Comments in Manifests.
