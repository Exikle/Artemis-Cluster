# Skill: Add OIDC App (Pocket-ID)

Wire a new application into Pocket-ID for single sign-on. Pocket-ID is at `https://auth.dcunha.io` (security namespace, web UI config — no CLI tools pod needed).

## Group Structure

| Group    | Access Level                                 |
| -------- | -------------------------------------------- |
| `admins` | Full access everywhere                       |
| `infra`  | Infra apps (Grafana, code-server candidates) |
| `users`  | General apps (books, media, etc.)            |

## Step 1 — Create OIDC Client in Pocket-ID

1. Log into `https://auth.dcunha.io` as admin
2. Navigate to **OIDC Clients** → **New Client**
3. Set:
    - **Client ID**: `<app>` (lowercase, matches app name)
    - **Name**: human-readable display name
    - **Allowed callback URLs**: `https://<app-hostname>/<oidc-callback-path>` (check app docs for exact path)
    - **PKCE**: enabled by default — **disable if the app uses authlib** (authlib loses `code_verifier` between redirect and callback)
4. Save and copy the **Client Secret**

## Step 2 — Save Secret to 1Password

Save to the app's 1Password item (create if needed). Key name depends on how the app reads it:

| App pattern                    | Key name                              |
| ------------------------------ | ------------------------------------- |
| Env var prefix (e.g. bookboss) | `BOOKBOSS__OIDC__CLIENT_SECRET`       |
| Generic oauth (e.g. Grafana)   | `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` |
| Spring OAuth2 (e.g. Komga)     | `KOMGA_OIDC_CLIENT_SECRET`            |
| Open WebUI                     | `OAUTH_CLIENT_SECRET`                 |

## Step 3 — Add ExternalSecret

Add to the app's `externalsecret.yaml` (or create one):

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
    name: <app>
spec:
    dataFrom:
        - extract:
              key: <app>
    refreshInterval: 1h
    secretStoreRef:
        kind: ClusterSecretStore
        name: onepassword-connect
    target:
        name: <app>
        template:
            data:
                <SECRET_ENV_VAR>: "{{ .<KEY_NAME> }}"
```

## Step 4 — Configure the App

### Native OIDC (env vars) — bookboss pattern

```yaml
env:
    BOOKBOSS__OIDC__ISSUER: "https://auth.dcunha.io"
    BOOKBOSS__OIDC__CLIENT_ID: "<app>"
    BOOKBOSS__OIDC__CLIENT_SECRET:
        valueFrom:
            secretKeyRef:
                name: <app>
                key: BOOKBOSS__OIDC__CLIENT_SECRET
```

### Generic OAuth — Grafana pattern

```yaml
env:
    GF_AUTH_GENERIC_OAUTH_ENABLED: "true"
    GF_AUTH_GENERIC_OAUTH_NAME: "Pocket-ID"
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID: "grafana"
    GF_AUTH_GENERIC_OAUTH_AUTH_URL: "https://auth.dcunha.io/authorize"
    GF_AUTH_GENERIC_OAUTH_TOKEN_URL: "https://auth.dcunha.io/api/oidc/token"
    GF_AUTH_GENERIC_OAUTH_API_URL: "https://auth.dcunha.io/api/oidc/userinfo"
    GF_AUTH_GENERIC_OAUTH_SCOPES: "openid email profile groups"
    # Role mapping via JMESPath (groups claim):
    GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH: "contains(groups[*], 'admins') && 'Admin' || contains(groups[*], 'infra') && 'Editor' || 'Viewer'"
```

### oauth2-proxy (apps without native OIDC)

Use the existing `oauth2-proxy` at `oauth.dcunha.io` (security namespace). Add a SecurityPolicy to the app's HTTPRoute — see `kubernetes/apps/security/oauth2-proxy/` for the pattern.

Cookie secret must be exactly 16/24/32 bytes:

```bash
python3 -c "import os,base64; print(base64.urlsafe_b64encode(os.urandom(24)).decode().rstrip('='))"
```

## Step 5 — Test

```bash
kubectl rollout restart deployment <app> -n <namespace>
kubectl logs -n <namespace> deployment/<app> --tail=30
```

Navigate to `https://<app-hostname>` — should redirect to Pocket-ID login.

## Gotchas

- **PKCE**: disable on Pocket-ID client for apps using authlib (Open WebUI) — authlib loses `code_verifier`
- **Grafana user conflict**: if existing user has `isExternal=false`, OAuth won't link — delete via Grafana API and let OAuth recreate
- **Home Assistant**: no external OIDC auth provider support in HA core — `type: oidc` does not exist
- **oauth2-proxy cookie secret**: must be exactly 32 chars — use the `python3` command above, do not truncate
