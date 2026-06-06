# Checklist: app/externalsecret.yaml

Only run this checklist if an `externalsecret.yaml` file is present.

Mark each item **PASS**, **FAIL**, or **N/A**.

| #   | Check                                                                  | Result |
| --- | ---------------------------------------------------------------------- | ------ |
| E1  | `apiVersion: external-secrets.io/v1` (not `v1beta1`)                   |        |
| E2  | `secretStoreRef.kind: ClusterSecretStore`, `name: onepassword-connect` |        |
| E3  | `refreshInterval: 1h`                                                  |        |
| E4  | `target.name` matches app name                                         |        |
| E5  | `dataFrom[].extract.key` matches the exact 1Password item name         |        |
| E6  | Template field names use `{{ .FIELD_NAME }}` syntax                    |        |
