# Module: HelmRelease Template

`spec` field order: `chartRef → interval → dependsOn → install → upgrade → values → postRenderers`

`postRenderers` is last and is easy to forget — only a couple of apps use it (see
`.agents/references/observability.md` for the pattern). Canonical ordering lives in
`.agents/instructions/yaml-conventions.md`; this is a convenience copy.

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
                    - name: internal-gateway
                      namespace: network
        service:
            app:
                ports:
                    http:
                        port: <port>
```

## Gateways — pick by hostname suffix

| Gateway            | Hostnames         | Exposure                                       |
| ------------------ | ----------------- | ---------------------------------------------- |
| `internal-gateway` | `*.dcunha.io`     | LAN only                                       |
| `external-gateway` | `*.dcunha.io`     | Public via Cloudflare tunnel                   |
| `edge-gateway`     | `*.frostlink.dev` | Public via towonel — **ClusterIP**, HTTPS-only |

All three live in `namespace: network`. `edge-gateway` is the one commonly forgotten; it is a
real live gateway used by `media/jellyfin`, `arcade/eco` and `network/echo`. An app can attach
to more than one by adding a second named route:

```yaml
route:
    app:
        hostnames:
            - <app>.dcunha.io
        parentRefs:
            - name: external-gateway
              namespace: network
    frostlink:
        hostnames:
            - <app>.frostlink.dev
        parentRefs:
            - name: edge-gateway
              namespace: network
```

Details and the towonel origin mapping: `.agents/references/towonel-agent.md`.

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
- **The YAML blocks above render at 4-space indent — real manifests are 2-space.** Do not copy
  the indentation. oxfmt (lefthook pre-commit, `printWidth 100`) reformats YAML inside markdown
  code fences to its own 4-space style and will undo any attempt to fix it here, while
  `.editorconfig` sets `indent_size = 2` for `*.yaml` under `kubernetes/`. Copy the structure,
  re-indent to 2.
