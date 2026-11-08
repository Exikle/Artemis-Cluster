# Module: app/kustomization.yaml Template

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.config.k8s.io/kustomization_v1beta1.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
    - ./helmrelease.yaml
    - ./ocirepository.yaml
```

No `./externalsecret.yaml`: app-template apps define secrets inline in the HelmRelease. See
`externalsecret.md`.

## With a config file the app reads from disk

Several apps need a real file mounted, not env vars. Generate the file. Do not hand-write a
ConfigMap. Disable Flux variable substitution on it so that `$` in the payload survives:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.config.k8s.io/kustomization_v1beta1.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
    - ./helmrelease.yaml
    - ./ocirepository.yaml
configMapGenerator:
    - name: <app>-config
      files:
          - config.yaml=./resources/config.yaml
generatorOptions:
    disableNameSuffixHash: true
    annotations:
        kustomize.toolkit.fluxcd.io/substitute: disabled
```

## Notes

- YAML blocks in these templates render at 4-space indent, but real manifests use 2 spaces. Copy the
  structure, not the indentation (`yaml-conventions.md` § What the tooling does for you).
- `apiVersion` is always `kustomize.config.k8s.io/v1beta1`. `v1` does not exist for this kind.
- The schema URL is the `k8s-schemas.home-operations.com` one, not
  `https://json.schemastore.org/kustomization`. The `.k8s-schema-hook.yaml` pre-commit hook
  rewrites it to the home-operations URL anyway, so if you write the schemastore one, you get
  a diff on your first commit.
- `resources` is sorted alphabetically, per `yaml-conventions.md`, and not in deployment order.
- `generatorOptions.annotations.kustomize.toolkit.fluxcd.io/substitute: disabled` is required on
  any generated ConfigMap whose payload contains `${...}`. Without it, the `postBuild`
  substitution of Flux removes the value and the app gets an empty value.
