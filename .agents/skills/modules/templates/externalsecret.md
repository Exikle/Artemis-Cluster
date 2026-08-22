# Module: ExternalSecret Template

Only create this file if the app needs secrets from 1Password.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
    name: <app>
spec:
    dataFrom:
        - extract:
              key: <1password-item-name>
    refreshInterval: 1h
    secretStoreRef:
        kind: ClusterSecretStore
        name: onepassword-connect
    target:
        name: <app>
        template:
            data:
                SOME_KEY: "{{ .FIELD_NAME }}"
```

## Notes

- **The YAML blocks above render at 4-space indent — real manifests are 2-space.** Do not copy
  the indentation. oxfmt (lefthook pre-commit, `printWidth 100`) reformats YAML inside markdown
  code fences to its own 4-space style and will undo any attempt to fix it here, while
  `.editorconfig` sets `indent_size = 2` for `*.yaml` under `kubernetes/`. Copy the structure,
  re-indent to 2.
- Do NOT add `namespace:` to metadata — the Flux Kustomization's `targetNamespace` injects it.
- `apiVersion` must be `external-secrets.io/v1` — `v1beta1` is removed.
- `secretStoreRef.name` must be `onepassword-connect` (not `onepassword`, not `1password-connect`).
- `dataFrom.extract.key` is the exact name of the 1Password item.
- Template field names must **exactly** match 1Password field names — a mismatch returns an empty secret with no error.
- `target.name` should match the app name so the Secret is predictably named.
- Add `onepassword-connect` to `dependsOn` in `ks.yaml` whenever an ExternalSecret is present.
- `spec` is plain alphabetical: `dataFrom → refreshInterval → secretStoreRef → target`.
