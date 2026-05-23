# Module: app/kustomization.yaml Template

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ocirepository.yaml
  - ./helmrelease.yaml
  # - ./externalsecret.yaml   # uncomment if using secrets
```

## Notes

- `apiVersion` is always `kustomize.config.k8s.io/v1beta1` — `v1` does not exist for this kind.
- Include `externalsecret.yaml` in resources only when the file exists.
- Resource order: ocirepository → helmrelease → externalsecret (alphabetical within type).
