# Secrets

All secrets are managed via [External Secrets Operator (ESO)](https://external-secrets.io/) backed by [1Password Connect](https://developer.1password.com/docs/connect/). There is no SOPS encryption at runtime.

---

## Architecture

```
1Password vault ("kubernetes")
  └── 1Password Connect server (in-cluster, external-secrets namespace)
        └── ClusterSecretStore "onepassword-connect"
              └── ExternalSecret resources → Kubernetes Secrets
```

---

## Components

| Component                                | Namespace          | Purpose                             |
| ---------------------------------------- | ------------------ | ----------------------------------- |
| `external-secrets`                       | `external-secrets` | ESO operator                        |
| `onepassword-connect`                    | `external-secrets` | 1Password Connect server            |
| `ClusterSecretStore/onepassword-connect` | cluster-scoped     | Provider config pointing to Connect |

---

## ClusterSecretStore

The `onepassword-connect` ClusterSecretStore is the single provider used by all ExternalSecrets in the cluster. It connects to the in-cluster Connect server:

```yaml
spec:
    provider:
        onepassword:
            connectHost: http://onepassword-connect.external-secrets.svc.cluster.local
            vaults:
                kubernetes: 1
```

---

## Bootstrap Secrets

Two secrets must exist **before** ESO or 1Password Connect are installed. They are created by the `just bootstrap resources` stage from `bootstrap/resources.yaml.j2` (rendered with `op` CLI):

| Secret                                   | Namespace          | Contains                     |
| ---------------------------------------- | ------------------ | ---------------------------- |
| `onepassword-connect-credentials-secret` | `external-secrets` | `1password-credentials.json` |
| `onepassword-connect-vault-secret`       | `external-secrets` | Connect API token            |
| `cloudflare-tunnel-id-secret`            | `network`          | `CLOUDFLARE_TUNNEL_ID`       |

All values are sourced from `op://kubernetes/1password/*` and `op://kubernetes/cloudflare/*`.

---

## Using ExternalSecrets in Apps

Reference the ClusterSecretStore in any namespace:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
    name: my-app-secret
    namespace: my-namespace
spec:
    refreshInterval: 1h
    secretStoreRef:
        kind: ClusterSecretStore
        name: onepassword-connect
    target:
        name: my-app-secret
        creationPolicy: Owner
    data:
        - secretKey: MY_API_KEY
          remoteRef:
              key: my-app # 1Password item name in "kubernetes" vault
              property: MY_API_KEY # 1Password field name
```

---

## Troubleshooting

```bash
# Check ESO is running
kubectl get pods -n external-secrets

# Check a specific ExternalSecret status
kubectl describe externalsecret <name> -n <namespace>

# Check ClusterSecretStore connectivity
kubectl describe clustersecretstore onepassword-connect

# Check Connect server logs
kubectl logs -n external-secrets deploy/onepassword-connect
```

If Connect cannot reach 1Password servers, check that the `onepassword-connect-credentials-secret` JSON is valid and the Connect token has access to the `kubernetes` vault.
