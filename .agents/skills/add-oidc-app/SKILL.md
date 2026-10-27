---
name: add-oidc-app
description: Wire an app into Pocket-ID for single sign-on — create the OIDC client, store the secret in 1Password, and configure the app's OIDC settings and redirect URIs. Use for "add SSO to X", "wire X into Pocket-ID", "set up OIDC for X", or "single sign-on for X". Scoped to the Artemis cluster.
compatibility: Requires Pocket-ID reachable at `https://id.dcunha.io` with `pocket-id-operator` running, and the `op` CLI signed in to write the client secret into 1Password.
---

# Skill: Add OIDC App (Pocket-ID)

Wire a new application into Pocket-ID for single sign-on. Pocket-ID is at `https://id.dcunha.io`
(security namespace), operator-managed (`pocket-id-operator`) — clients are declared as
`PocketIDOIDCClient` CRs, never created by hand in the web UI.

> Read `.agents/references/networking.md` for gateway names and route syntax before adding any
> HTTPRoute. Edit in a worktree: `just wt new feat/<slug>` first (`AGENTS.md` rule 7). An app that
> cannot do OIDC itself uses `components/envoy-oidc` (Step 2, last section). The tinyauth gate is a
> different mechanism: `.agents/skills/add-tinyauth-app/SKILL.md`.

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
    pkceEnabled: true # false only if the app cannot send a code_challenge (see Gotchas)
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

### Servarr native OIDC — sonarr / radarr pattern

Single-user, `SONARR__AUTH__METHOD: Oidc` plus `SONARR__AUTH__OIDC*` env vars, callback
`/signin-oidc`. `SONARR__AUTH__REQUIRED` must be `Enabled` and `SONARR__SERVER__TRUSTEDNETWORKS`
must hold the pod CIDR, or the redirect URI comes out `http://`. Copy
`kubernetes/apps/media/sonarr/` or `radarr/`; the traps are in `identity-stack.md` § Sonarr v5
and Radarr v7.

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

`OIDC_CLIENT_SECRET` injected from Secret via `envFrom`. Callback URL: `https://<hostname>/api/auth/oidc/callback`.

### Envoy Gateway OIDC via `components/envoy-oidc` (apps without native OIDC support)

Envoy handles the whole OIDC flow, so the app needs no sidecar. Do not use oauth2-proxy with Envoy
ExtAuth: Envoy does not forward `Set-Cookie` from the auth service's 302, so every callback fails
with "CSRF cookie not found".

Add the component to the app's `ks.yaml`; it renders a `SecurityPolicy` named `<app>-oidc` against
the app's HTTPRoute. Copy the shape from `kubernetes/apps/media/bazarr/ks.yaml`
(`grep -rln 'components/envoy-oidc' kubernetes/apps` lists every consumer):

```yaml
dependsOn:
    - name: pocket-id-operator
      namespace: security
components:
    - ../../../../components/envoy-oidc
postBuild:
    substitute:
        APP: *app
```

Optional substitutions: `OIDC_HOST` (default `<app>.dcunha.io`) and `HTTP_ROUTE_TARGET` (default
`<app>`, the HTTPRoute name).

Also write `app/oidcclient.yaml` (add it to `app/kustomization.yaml`) as in Step 1, with
`callbackUrls: https://<host>/oauth2/callback`, `pkceEnabled: true` and
`secret.keys.clientSecret: client-secret`. The component reads the operator's
`<app>-oidc-credentials` Secret, and Envoy needs the key to be literally `client-secret`.
`kubernetes/apps/media/bazarr/app/oidcclient.yaml` is the reference.

## Step 3 — Test

Apply and commit per `.agents/skills/modules/test-and-commit.md`, then:

```bash
kubectl rollout restart deployment <app> -n <namespace>
kubectl logs -n <namespace> deployment/<app> --tail=30
```

Navigate to `https://<app-hostname>` — should redirect to Pocket-ID login.

## Gotchas

- **PKCE**: default to `pkceEnabled: true`. `{"error":"Invalid code verifier"}` from Pocket-ID means the client promised PKCE and the app sent no `code_challenge` — the fix is to make the app send one, not to assume it cannot. Two known cases, both checked against upstream source on 2026-09-20:
    - **django-allauth (Paperless-NGX)**: supports PKCE, but it is opt-in and defaults off (`OAuth2Provider.pkce_enabled_default = False`). Add `"oauth_pkce_enabled": true` to the app's `settings` block in `PAPERLESS_SOCIALACCOUNT_PROVIDERS`. Keep the client secret — a confidential client with PKCE is fine. The earlier claim here that allauth "loses the `code_verifier` between redirect and callback" was wrong; it stashes the verifier in session state and reads it back.
    - **Spring Security (Komga)**: 6.5.x only sends a `code_challenge` for PUBLIC clients — `ClientSettings.requireProofKey` defaults to `false` and Spring Boot exposes no client-side property to flip it. A confidential client cannot do PKCE at all. Leave `pkceEnabled: false` unless you also drop the secret and set `client-authentication-method: none` on both sides. (Spring Security 7.x changes this default — do not trust its main-branch docs for a 6.5 app.)
- **Existing account linking (django-allauth)**: if a local account already exists with the same email, allauth won't auto-link on first OIDC login — add `"EMAIL_AUTHENTICATION": true` to the `openid_connect` block in `PAPERLESS_SOCIALACCOUNT_PROVIDERS` to enable auto-connect by email
- **Grafana user conflict**: if existing user has `isExternal=false`, OAuth won't link — delete via Grafana API and let OAuth recreate
- **Home Assistant**: no external OIDC auth provider support in HA core — `type: oidc` does not exist
- **`passThroughAuthHeader`**: requires JWT validation settings (`jwt` block). Omit it unless you also configure JWKS.
