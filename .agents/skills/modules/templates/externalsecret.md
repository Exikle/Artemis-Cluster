# Module: ExternalSecret Template

Only add this if the app needs secrets from 1Password. For app-template apps it goes **inline in
`helmrelease.yaml`**, not in a separate file:

```yaml
spec:
    values:
        externalSecrets:
            env:
                dataFrom:
                    - extract:
                          key: <1password-item-name>
                secretStoreRef:
                    kind: ClusterSecretStore
                    name: onepassword-connect
                target:
                    template:
                        data:
                            SOME_KEY: "{{ .FIELD_NAME }}"
```

Reference it from a container with `envFrom: [{externalSecretRef: {identifier: env}}]`.

## Notes

- `secretStoreRef.name` must be `onepassword-connect` (not `onepassword`, not `1password-connect`).
- `dataFrom.extract.key` is the exact name of the 1Password item.
- Template field names must **exactly** match 1Password field names — a mismatch returns an empty secret with no error.
- Naming: with one entry the ExternalSecret and its Secret are named after the release; with
  several, `<release>-<id>`. `target.name` overrides the Secret name, `forceRename` the
  ExternalSecret name.
- The chart sets `target.deletionPolicy: Delete` by default.
- Add `onepassword-connect` to `dependsOn` in `ks.yaml` whenever an ExternalSecret is present.
- A standalone `externalsecret.yaml` (`apiVersion: external-secrets.io/v1`, no `namespace:`,
  `spec` alphabetical: `dataFrom → refreshInterval → secretStoreRef → target`) is only for the
  exceptions in `cluster-conventions.md` § Secrets.
