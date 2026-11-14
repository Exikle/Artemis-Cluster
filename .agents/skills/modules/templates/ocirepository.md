# Module: OCIRepository Template

Every app gets its own standalone OCIRepository. Never share one between apps.

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
        tag: <app-template version>
    url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

## Notes

- `name` must match the app name, because `chartRef.name` in the HelmRelease references it.
- `url` must use `bjw-s-labs` (not `bjw-s`). A wrong org path fails silently.
- `apiVersion` must be `source.toolkit.fluxcd.io/v1`. `v1beta2` is removed.
- `ref.tag` is the app-template chart version (bare, no SHA pinning for Helm charts), not the app image tag.
- Do not add `namespace:` to metadata. The `targetNamespace` of the Flux Kustomization injects it.

## Values that drift: recover them from the tree

Renovate bumps `ref.tag` fleet-wide, so a number written here goes stale by design. These commands print the current
tag and the usual `interval`:

```bash
grep -h 'tag:' clusters/artemis/kubernetes/apps/*/*/app/ocirepository.yaml | sort | uniq -c | sort -rn | head -1
grep -h 'interval:' clusters/artemis/kubernetes/apps/*/*/app/ocirepository.yaml | sort | uniq -c | sort -rn | head -1
```
