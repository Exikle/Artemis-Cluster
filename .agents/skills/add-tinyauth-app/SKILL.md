---
name: add-tinyauth-app
description: Put an app behind tinyauth via Envoy Gateway ext_authz, for apps with no native OIDC support. Use for "protect X with tinyauth", "gate X behind tinyauth", "shared login for X", or "ext_authz for X". Scoped to the Artemis cluster.
---

# Skill: Add Tinyauth Protection to an App

Gate an app behind the shared `tinyauth` forward-auth service. It uses a Pocket-ID passkey login with an
lldap password fallback, and one shared login and session for every protected app.

tinyauth is the standard gate for apps without native OIDC. You can also put it in front of apps
that have native OIDC. The alternative is `components/envoy-oidc`, a per-app Envoy OIDC client (see
`.agents/skills/add-oidc-app/SKILL.md`). Apps with real user models also keep their native
`PocketIDOIDCClient` for in-app identity, which tinyauth does not replace.

Read `.agents/references/identity-stack.md` in full before you proceed. It covers the lldap,
Pocket-ID and tinyauth chain, the `ResourceSet` grant mechanism, the session handoff, and every
gotcha found while building this.

> Since 2026-08-24, `TINYAUTH_AUTH_ACLS_POLICY` is `deny`. tinyauth **denies** an app that has no `TINYAUTH_APPS_*`
> entry. It does not leave the app open. This inverts the old failure mode: if you forgot Step 3, the app stayed wide open.
> Now you are locked out of it instead. The gate fails closed, so do not mistake
> the resulting 403 for a broken gate.

---

## Step 1: Add the component to the app's `ks.yaml`

```yaml
components:
    - ../../../../components/tinyauth
```

Also remove any existing `oidcclient.yaml` for that app and its `pocket-id-operator` dependency.
tinyauth is the OIDC client now, not the app itself.

Do **not** add a `dependsOn` on tinyauth. The repo removed availability-gating edges deliberately. The `SecurityPolicy` applies with or without a healthy
tinyauth, and Envoy programs it when the backend appears.

## Step 2: Grant the app's namespace access to the tinyauth Service

Gateway API requires a `ReferenceGrant` that the namespace which owns the target resource declares
(`security`, where the `tinyauth` Service lives), never the consumer. The `ResourceSet` at
`kubernetes/apps/security/tinyauth/app/resourceset.yaml` generates it. Check its
`spec.inputs` first. If the namespace is already listed (`media` is), skip this step entirely.
Otherwise add one line:

```yaml
spec:
    inputs:
        - namespace: media
        - namespace: <new-namespace> # add this
```

Do not create a per-app or per-namespace file. The repo tried that and reverted it twice. Also,
`inputsFrom` on a `ResourceSet` is namespace-scoped (the CRD says: "an input provider resource in
the same namespace as the ResourceSet"). You cannot use the `external-endpoints` provider pattern
here to move this next to the app. The repo evaluated it and rejected it on 2026-08-24.

## Step 3: Set the per-app ACL (three keys, all mandatory)

Add to `security/tinyauth/app/helmrelease.yaml`, container env:

```yaml
env:
    TINYAUTH_APPS_<APPNAME_UPPERCASE>_OAUTH_WHITELIST: "/.*/"
    TINYAUTH_APPS_<APPNAME_UPPERCASE>_OAUTH_GROUPS: app_admin,app_ops
    TINYAUTH_APPS_<APPNAME_UPPERCASE>_LDAP_GROUPS: app_admin,app_ops
```

| Key                | Checked for              | If unset, under `policy: deny`    |
| ------------------ | ------------------------ | --------------------------------- |
| `_OAUTH_WHITELIST` | OAuth email, **first**   | abstains → **denies** OAuth users |
| `_OAUTH_GROUPS`    | Pocket-ID session groups | abstains → **denies**             |
| `_LDAP_GROUPS`     | lldap password session   | abstains → **denies**             |

tinyauth checks groups per login provider, so there are two group keys. The same underscored
name works for both, because Pocket-ID syncs its groups from lldap.

- `APPNAME` must match the app's subdomain. ext_authz resolves the ACL from the request host
  (`frigate.dcunha.io` → `frigate`), and `auth.subdomainsEnabled` defaults true, so
  `_CONFIG_DOMAIN` is not needed.
- Group values use underscores (`app_admin`), not the hyphenated `PocketIDUserGroup` CR name
  (`app-admin`). See `identity-stack.md` § Groups.
- `"/.*/"` is a match-all regex, not a placeholder. Keep it. The group lists are the real gate.
- Never remove the global `TINYAUTH_OAUTH_WHITELIST: "/.*/"`. Under `policy: deny`, an unset
  global whitelist abstains and denies _every_ Pocket-ID login at the OAuth callback, before any
  app ACL runs. This includes Immich. See `identity-stack.md` § Gating apps.

## Step 4: Optional, hand the app an authenticated session

By default tinyauth only gates the route, so an app with its own login still shows it. If the app
supports trusted headers, add the ones it needs to `headersToBackend` in
`components/tinyauth/securitypolicy.yaml`. tinyauth sets `Remote-User`, `Remote-Name`,
`Remote-Email`, `Remote-Groups` and `Remote-Sub`, but none reach the backend unless you name them there.

If the app has no header-auth mode, tinyauth can create basic-auth credentials instead:

```yaml
TINYAUTH_APPS_<APP>_RESPONSE_BASICAUTH_USERNAME: <user>
TINYAUTH_APPS_<APP>_RESPONSE_BASICAUTH_PASSWORDFILE: /secrets/oidc/<app>-basic-password
```

Put the password in the app's own 1Password item in the `artemis` vault. Look in every vault
first, because a duplicate title in a higher-priority vault silently shadows the real one. Pull the password
into the `tinyauth` ExternalSecret with an extra `dataFrom.extract`. It lands under
`/secrets/oidc/` because the whole Secret is mounted there.
`Authorization` is already in `headersToBackend`. Then turn the app's own auth on. No app uses
this today. `identity-stack.md` § Handing the app an authenticated session describes the mechanics.

## Step 5: Test live before committing

Follow `.agents/skills/modules/test-and-commit.md` (edit in a worktree: `just wt new feat/<slug>`).
Suspend the root and each target. Apply both `security tinyauth` and the app, then:

```bash
curl -sI https://<app-hostname>/ 2>&1 | head -5
# expect: HTTP/2 401, x-tinyauth-location pointing at tinyauth's login
```

Dump the parsed config to make sure that the ACL landed. `tinyauth config` is the fastest way to see what tinyauth really believes:

```bash
kubectl exec -n security <tinyauth-pod> -c app -- /tinyauth/tinyauth config
```

> The dump is not redacted. It prints `ldap.bindPassword` and OIDC `clientSecret` in
> plaintext. Always filter it before you paste it anywhere: `| grep -vi 'password\|secret'`.

The only reliable way to confirm that the group ACL works is a negative test against your own
account. Temporarily set the group requirement to a nonexistent group. Make sure that your own
authenticated session is denied. Then set it back and make sure that access returns. A positive-only
test cannot tell "correctly allowed" from "no ACL enforced at all".

---

## Gotchas

- ext_authz intercepts every external request on the route, not only browsers. Mobile apps,
  API tokens and webhooks break unless you exempt them through `TINYAUTH_APPS_<NAME>_PATH_ALLOW`, or the
  caller's IP through `_IP_BYPASS`. Internal `svc.cluster.local` traffic never touches the gateway, so
  it is unaffected. This is why probes and app-to-app calls keep working.
- Label-based ACL discovery watches `networking.k8s.io/v1 Ingress` only, never Gateway API
  `HTTPRoute`. This cluster uses only Gateway API, so `TINYAUTH_LABELPROVIDER: none` is
  permanent. If you mount a ServiceAccount token, the provider still has nothing to read. Always use
  the explicit `TINYAUTH_APPS_*` env.
- The login flow shows one page. `TINYAUTH_OAUTH_AUTOREDIRECT: pocketid` plus `skipConsent` on
  the client sends users straight to the passkey prompt. Auto-redirect only fires when the request
  carries `redirect_uri` or `oidc_ticket`. If you visit `auth.dcunha.io` **directly**, it still shows
  the lldap password form. That is the break-glass path, so do not "fix" it.
- Pocket-ID names the gate, not the app. Its consent/authorize screen says _Artemis SSO_
  because tinyauth is the only client it has. Pocket-ID cannot see any tinyauth-gated app. For that
  reason, per-app authorization must live in `TINYAUTH_APPS_*`.
- Sessions live in sqlite on an emptyDir (`/data/tinyauth.db`). Every tinyauth pod restart
  logs everyone out of every protected app. This is deliberate for now: a restart revokes all sessions cluster-wide.
  Otherwise sessions last `SESSIONEXPIRY` (7 days), which is also the revocation lag
  for a user that you disable in lldap. `LDAP_GROUPCACHETTL` adds up to 15 min of lag on group changes.
- tinyauth runs as root. The image has no `USER` directive, so `runAsUser: 0` and
  `readOnlyRootFilesystem: false` are required. Skip the usual non-root review checks for this app.
- The password fallback goes from tinyauth to lldap directly, not through Pocket-ID, which is passkey-only even
  for LDAP-synced users. Do not configure `TINYAUTH_AUTH_USERS`. That would be a second, unsynced
  credential store.
