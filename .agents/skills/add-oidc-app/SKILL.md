---
name: add-oidc-app
description: Wire an app into Pocket-ID for single sign-on — create the OIDC client, store the secret in 1Password, and configure the app's OIDC settings and redirect URIs. Use for "add SSO to X", "wire X into Pocket-ID", "set up OIDC for X", or "single sign-on for X". Scoped to the Artemis cluster.
---

# Skill: Add OIDC App (Pocket-ID)

Wire a new application into Pocket-ID for single sign-on. Pocket-ID is at `https://id.dcunha.io`
(security namespace), operator-managed (`pocket-id-operator`) — clients are declared as
`PocketIDOIDCClient` CRs, never created by hand in the web UI.

> Read `.agents/references/networking.md` for gateway names and route syntax before adding any
> HTTPRoute or SecurityPolicy. If the app has no native OIDC support, gate it with tinyauth
> instead — see `.agents/skills/add-tinyauth-app/SKILL.md` and the identity-stack reference
> (`components/envoy-oidc` was removed 2026-07-15; it never gained a consumer).

## Group Structure

| Group       | Access Level                   |
| ----------- | ------------------------------ |
| `app-admin` | Full access to admin-tier apps |
| `app-ops`   | Operational/infra apps         |
| `app-users` | General apps                   |

Groups are lldap-synced (`ID-Admin`/`ID-Ops`/`ID-Users` in lldap, `app_admin`/`app_ops`/
`app_users` as the Pocket-ID group `name` — underscored, not the hyphenated
`PocketIDUserGroup` CR name). See `.agents/references/identity-stack.md` for the full lldap →
Pocket-ID chain.

## Step 1 — Create the `PocketIDOIDCClient` CR

Colocate it with the app's own manifests (e.g. `<app>/app/oidcclient.yaml`), not in a central
folder — matches every existing app. **Always set `spec.clientID` explicitly** — leaving it to
name-fallback matching caused a real incident where the operator minted a random UUID client ID
on a later reconcile, silently breaking live SSO with no CR-status error surfaced.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/pocketid.internal/pocketidoidcclient_v1alpha1.json
apiVersion: pocketid.internal/v1alpha1
kind: PocketIDOIDCClient
metadata:
    name: <app>
spec:
    allowedUserGroups:
        - name: app-admin # or app-ops / app-users — the CR name, hyphenated
          namespace: security
    callbackUrls:
        - "https://<app-hostname>/<oidc-callback-path>" # check app docs for exact path
    clientID: <app>
    launchUrl: "https://<app-hostname>/"
    logo:
        autoGenerate: false
    pkceEnabled: false # true only if the app isn't authlib/django-allauth (see Gotchas)
    secret:
        storeClientSecret: true
```

The operator creates a Secret automatically — **no manual 1Password copy-and-paste needed** as
long as the app can consume the operator's own key names, or you customize them to match what the
app expects directly:

```yaml
secret:
    keys:
        clientID: <ENV_VAR_NAME_FOR_CLIENT_ID>
        clientSecret: <ENV_VAR_NAME_FOR_CLIENT_SECRET>
```

Then reference it straight from the app's container via `envFrom: [{ secretRef: { name:
<app>-oidc-credentials } }]` (secret name defaults to `<client-name>-oidc-credentials`). This
fully replaces the old manual-secret workflow.

> All YAML written or modified by this skill must follow the field ordering rules in
> `.agents/instructions/yaml-conventions.md`.

## Step 2 — Configure the App

### Native OIDC (env vars) — bookboss pattern

```yaml
env:
    BOOKBOSS__OIDC__ISSUER: "https://id.dcunha.io"
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
    GF_AUTH_GENERIC_OAUTH_AUTH_URL: "https://id.dcunha.io/authorize"
    GF_AUTH_GENERIC_OAUTH_TOKEN_URL: "https://id.dcunha.io/api/oidc/token"
    GF_AUTH_GENERIC_OAUTH_API_URL: "https://id.dcunha.io/api/oidc/userinfo"
    GF_AUTH_GENERIC_OAUTH_SCOPES: "openid email profile groups"
    # Role mapping via JMESPath (groups claim):
    GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH: "contains(groups[*], 'admins') && 'Admin' || contains(groups[*], 'infra') && 'Editor' || 'Viewer'"
```

### Shelfmark-style native OIDC (`AUTH_METHOD=oidc`)

Apps that expose OIDC via env vars with `AUTH_METHOD=oidc`:

```yaml
env:
    AUTH_METHOD: oidc
    OIDC_DISCOVERY_URL: "https://id.dcunha.io/.well-known/openid-configuration"
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
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.envoyproxy.io/securitypolicy_v1alpha1.json
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
            issuer: https://id.dcunha.io
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

## Step 3 — Test

```bash
kubectl rollout restart deployment <app> -n <namespace>
kubectl logs -n <namespace> deployment/<app> --tail=30
```

Navigate to `https://<app-hostname>` — should redirect to Pocket-ID login.

## Gotchas

- **PKCE**: disable on Pocket-ID client for apps using authlib or django-allauth (Paperless-NGX) — both lose `code_verifier` between redirect and callback; symptom is `{"error":"Invalid code verifier"}` in logs
- **Existing account linking (django-allauth)**: if a local account already exists with the same email, allauth won't auto-link on first OIDC login — add `"EMAIL_AUTHENTICATION": true` to the `openid_connect` block in `PAPERLESS_SOCIALACCOUNT_PROVIDERS` to enable auto-connect by email
- **Grafana user conflict**: if existing user has `isExternal=false`, OAuth won't link — delete via Grafana API and let OAuth recreate
- **Home Assistant**: no external OIDC auth provider support in HA core — `type: oidc` does not exist
- **Envoy native OIDC `clientSecret` key**: the K8s Secret referenced by `oidc.clientSecret.name` must contain a key literally named `client-secret` — any other key name and Envoy silently fails
- **`passThroughAuthHeader`**: requires JWT validation settings (`jwt` block) — omit it entirely unless you also configure JWKS; use `forwardAccessToken: false` instead
- **ExtAuth + oauth2-proxy is broken on Envoy**: CSRF cookie from the auth service 302 response is not forwarded to the browser — use native OIDC (`SecurityPolicy.oidc`) instead
