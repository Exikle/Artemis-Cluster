# Module: HelmRelease Template

`spec` field order: `chartRef → interval → dependsOn → install → upgrade → values`

`spec.values` order: `defaultPodOptions` first, then all other keys alphabetical.

## Minimal template

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
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
                    - name: internal-gateway # or external-gateway
                      namespace: network
        service:
            app:
                ports:
                    http:
                        port: <port>
```

## Notes

- Do NOT add `namespace:` to metadata — the Flux Kustomization's `targetNamespace` injects it.
- `fsGroup: 1000` only needed when the app uses a PVC.
- `readOnlyRootFilesystem: true` requires a `tmp` emptyDir entry. Use `advancedMounts` with `subPath` — even for a single path.
- Remove `persistence` block entirely if the app has no PVC and no writable paths.
- Remove `route` block if no ingress is needed.
- Never set `TZ` env var — k8tz handles timezone injection cluster-wide.
- `reloader.stakater.com/auto: "true"` must be on the controller annotation, not the pod.
- `startup` probe: include with `enabled: false` to be explicit, or omit entirely.
