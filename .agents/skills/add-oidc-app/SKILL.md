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

| App pattern                          | Key name                              |
| ------------------------------------ | ------------------------------------- |
| Env var prefix (e.g. bookboss)       | `BOOKBOSS__OIDC__CLIENT_SECRET`       |
| Generic oauth (e.g. Grafana)         | `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` |
| Spring OAuth2 (e.g. Komga)           | `KOMGA_OIDC_CLIENT_SECRET`            |
| Open WebUI                           | `OAUTH_CLIENT_SECRET`                 |
| Shelfmark-style (`AUTH_METHOD=oidc`) | `OIDC_CLIENT_SECRET`                  |
| Envoy native OIDC (SecurityPolicy)   | `client-secret` (Envoy hard-coded)    |

> All YAML written or modified by this skill must follow the field ordering rules in `.agents/instructions/sorting-instructions.md`.

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

### Shelfmark-style native OIDC (`AUTH_METHOD=oidc`)

Apps that expose OIDC via env vars with `AUTH_METHOD=oidc`:

```yaml
env:
    AUTH_METHOD: oidc
    OIDC_DISCOVERY_URL: "https://auth.dcunha.io/.well-known/openid-configuration"
    OIDC_CLIENT_ID: <app>
    OIDC_ADMIN_GROUP: admins
    OIDC_AUTO_REDIRECT: "true"
```

`OIDC_CLIENT_SECRET` injected from Secret via `envFrom`. Callback URL: `https://<hostname>/api/auth/oidc/callback`. PKCE: disable on Pocket-ID client (uses authlib).

### Envoy Gateway native OIDC (apps without native OIDC support)

Use `SecurityPolicy.oidc` — Envoy handles the full OIDC flow (redirects, CSRF, token exchange) internally. No sidecar or proxy needed.

**Do not use oauth2-proxy with Envoy ExtAuth.** Envoy's ExtAuth does not forward `Set-Cookie` from the auth service 302 redirect to the browser, so oauth2-proxy's CSRF cookie never reaches the client and every callback fails with "CSRF cookie not found". This is a fundamental Envoy limitation, not a config issue.

**ExternalSecret** — the Secret key must be literally `client-secret` (Envoy requirement):

```yaml
target:
    template:
        data:
            client-secret: "{{ .<APP>__OIDC__CLIENT_SECRET }}"
dataFrom:
    - extract:
          key: <app> # 1Password item name
```

**SecurityPolicy** (`securitypolicy.yaml`):

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/gateway.envoyproxy.io/securitypolicy_v1alpha1.json
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
    name: <app>
    namespace: <namespace>
spec:
    targetRefs:
        - group: gateway.networking.k8s.io
          kind: HTTPRoute
          name: <app>
    oidc:
        provider:
            issuer: https://auth.dcunha.io
        clientID: <app>
        clientSecret:
            name: <app> # Secret with key `client-secret`
        redirectURL: "https://<app-hostname>/oauth2/callback"
        scopes:
            - openid
            - profile
            - email
        forwardAccessToken: false
```

Add `securitypolicy.yaml` to the app's `kustomization.yaml` resources list.

Pocket-ID callback URL to register: `https://<app-hostname>/oauth2/callback`

## Step 5 — Test

```bash
kubectl rollout restart deployment <app> -n <namespace>
kubectl logs -n <namespace> deployment/<app> --tail=30
```

Navigate to `https://<app-hostname>` — should redirect to Pocket-ID login.

## Gotchas

- **PKCE**: disable on Pocket-ID client for apps using authlib (Open WebUI) or django-allauth (Paperless-NGX) — both lose `code_verifier` between redirect and callback; symptom is `{"error":"Invalid code verifier"}` in logs
- **Existing account linking (django-allauth)**: if a local account already exists with the same email, allauth won't auto-link on first OIDC login — add `"EMAIL_AUTHENTICATION": true` to the `openid_connect` block in `PAPERLESS_SOCIALACCOUNT_PROVIDERS` to enable auto-connect by email
- **Grafana user conflict**: if existing user has `isExternal=false`, OAuth won't link — delete via Grafana API and let OAuth recreate
- **Home Assistant**: no external OIDC auth provider support in HA core — `type: oidc` does not exist
- **Envoy native OIDC `clientSecret` key**: the K8s Secret referenced by `oidc.clientSecret.name` must contain a key literally named `client-secret` — any other key name and Envoy silently fails
- **`passThroughAuthHeader`**: requires JWT validation settings (`jwt` block) — omit it entirely unless you also configure JWKS; use `forwardAccessToken: false` instead
- **ExtAuth + oauth2-proxy is broken on Envoy**: CSRF cookie from the auth service 302 response is not forwarded to the browser — use native OIDC (`SecurityPolicy.oidc`) instead
