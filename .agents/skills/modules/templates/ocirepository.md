# Module: OCIRepository Template

Every app gets its own standalone OCIRepository — never shared.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
    name: <app>
spec:
    interval: 15m
    layerSelector:
        mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
        operation: copy
    ref:
        tag: 5.1.0
    url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

## Notes

- **The YAML blocks above render at 4-space indent — real manifests are 2-space.** Do not copy
  the indentation. oxfmt (lefthook pre-commit, `printWidth 100`) reformats YAML inside markdown
  code fences to its own 4-space style and will undo any attempt to fix it here, while
  `.editorconfig` sets `indent_size = 2` for `*.yaml` under `kubernetes/`. Copy the structure,
  re-indent to 2.
- `name` must match the app name — it is referenced by `chartRef.name` in the HelmRelease.
- `url` must use `bjw-s-labs` (not `bjw-s`) — wrong org path silently fails.
- `apiVersion` must be `source.toolkit.fluxcd.io/v1` — `v1beta2` is removed.
- OCIRepository chart tag uses a bare version (`5.1.0`) — no SHA pinning for Helm charts.
- `ref.tag` is the app-template chart version, not the app image tag.
- Do NOT add `namespace:` to metadata — the Flux Kustomization's `targetNamespace` injects it.

## Values that drift — check the live tree, not this file

| Field      | Live majority     | Wrong / stale                           |
| ---------- | ----------------- | --------------------------------------- |
| `ref.tag`  | `5.1.0` (all 56)  | `5.0.1` — the previous pin, now nowhere |
| `interval` | `15m` (89 of 109) | `1h` (18 live, older apps)              |

Renovate bumps `ref.tag` fleet-wide, so a number written down here goes stale by design.
Confirm before copying: `grep -rh -A1 "ref:" --include=ocirepository.yaml kubernetes/ | grep tag:`
