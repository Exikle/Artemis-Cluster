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
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 5.0.1
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

## Notes

- `name` must match the app name — it is referenced by `chartRef.name` in the HelmRelease.
- `url` must use `bjw-s-labs` (not `bjw-s`) — wrong org path silently fails.
- `apiVersion` must be `source.toolkit.fluxcd.io/v1` — `v1beta2` is removed.
- OCIRepository chart tag uses bare version (`5.0.1`) — no SHA pinning for Helm charts.
- `ref.tag` is the app-template chart version, not the app image tag.
- Do NOT add `namespace:` to metadata — the Flux Kustomization's `targetNamespace` injects it.
