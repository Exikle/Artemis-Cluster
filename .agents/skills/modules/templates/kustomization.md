# Module: app/kustomization.yaml Template

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.config.k8s.io/kustomization_v1beta1.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
    - ./externalsecret.yaml
    - ./helmrelease.yaml
    - ./ocirepository.yaml
```

Drop the `./externalsecret.yaml` line if the app has no secrets. Do **not** leave it in
commented out — `yaml-conventions.md` § No Comments in Manifests forbids commented-out
alternatives under `kubernetes/`.

## With a config file the app reads from disk

Several apps need a real file mounted, not env vars. Generate it rather than hand-writing a
ConfigMap, and disable Flux variable substitution on it so `$` in the payload survives:

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

- **The YAML blocks above render at 4-space indent — real manifests are 2-space.** Do not copy
  the indentation. oxfmt (lefthook pre-commit, `printWidth 100`) reformats YAML inside markdown
  code fences to its own 4-space style and will undo any attempt to fix it here, while
  `.editorconfig` sets `indent_size = 2` for `*.yaml` under `kubernetes/`. Copy the structure,
  re-indent to 2.
- `apiVersion` is always `kustomize.config.k8s.io/v1beta1` — `v1` does not exist for this kind.
- The schema URL is the `k8s-schemas.home-operations.com` one, **not**
  `https://json.schemastore.org/kustomization`. The `.k8s-schema-hook.yaml` pre-commit hook
  rewrites it to the home-operations URL anyway, so writing the schemastore one just produces
  a diff on your first commit.
- `resources` is sorted **alphabetically**, per `yaml-conventions.md` — so
  `externalsecret.yaml → helmrelease.yaml → ocirepository.yaml`, not deployment order. 44 live
  app kustomizations lead with `./externalsecret.yaml`.
- Include `./externalsecret.yaml` in `resources` only when the file actually exists.
- `generatorOptions.annotations.kustomize.toolkit.fluxcd.io/substitute: disabled` is required on
  any generated ConfigMap whose payload contains `${...}` — without it Flux's `postBuild`
  substitution eats it and the app gets an empty value.
