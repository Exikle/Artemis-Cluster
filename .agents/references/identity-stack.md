# Identity Stack — lldap → Pocket-ID → tinyauth

This file explains how the identity chain of this cluster fits together, and which auth mechanism to use. Verified
against the live cluster 2026-08-24.

This file records no versions. Renovate changes them often, and a pinned string in prose is stale within
the week. Read the tag off the HelmRelease:
`grep -A2 'tag:' kubernetes/apps/security/{pocket-id,tinyauth,lldap}/app/helmrelease.yaml`.

## The chain

```
lldap (security ns)  →  Pocket-ID (security ns, id.dcunha.io)  →  app-level auth
  directory: users,        OIDC provider, passkey-only login.       one of:
  groups, passwords         Syncs users/groups FROM lldap.          - native app OIDC client
                            Never verifies lldap passwords —        - components/tinyauth
                            Pocket-ID is passwordless for             (which ALSO binds lldap
                            every account, LDAP-synced or not.        directly for password
                                                                      fallback login, AND is
                                                                      itself an OIDC provider)
```

Three consumers exist, and it matters which one an app is on:

| Mechanism                       | Who is on it                                                                                                              |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Native `PocketIDOIDCClient`     | No roster here, because it changes. `kubectl get pocketidoidcclient -A`                                                   |
| `components/tinyauth` edge gate | No roster here, because it changes. `grep -rln 'components/tinyauth' kubernetes/apps/`, or the ground-truth command below |
| tinyauth's own OIDC provider    | Immich (see § tinyauth is also an OIDC provider)                                                                          |

`kubectl get pocketidoidcclient -A` is ground truth for the first row. For the second row, filter
`kubectl get securitypolicy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HTTP:.spec.extAuth.http.backendRefs[0].name`
to the tinyauth ones. `cortex/agentgateway` is a CORS policy, `network/edge` is extAuth over gRPC to the
CrowdSec bouncer (`crowdsec.md`), and the `*-oidc` ones are `components/envoy-oidc`.

No password ever reaches Pocket-ID. lldap has real password login (its own web UI at
`ldap.dcunha.io`, used for self-service profile management, plus the service-account bind
credential that Pocket-ID uses to read the directory). But Pocket-ID is exclusively passkey/WebAuthn
("Pocket ID only supports passwordless authentication", upstream docs), even for LDAP-synced
users. The LDAP sync provisions only _who_ the users and groups are. It is not a login mechanism.
Password fallback exists only because tinyauth binds lldap itself (`TINYAUTH_LDAP_*` env in
`security/tinyauth/app/helmrelease.yaml`). The login page of tinyauth offers "Login with Pocket-ID"
(passkey) plus a username/password form that validates directly against lldap, with the same directory and the same
groups.

## Pocket-ID: operator-managed, not app-template

`security/pocket-id/instance/` holds a `PocketIDInstance` CR. The operator
(`aclerici38/pocket-id-operator`) owns the Deployment, Service and HTTPRoute directly. It is not an
app-template HelmRelease. Postgres access uses the shared CNPG cluster via cert-manager mTLS
(`postgres-pocket-id-cert` + `postgres-server-ca`, mounted via `spec.podTemplate.spec.volumes` +
`persistence.extraVolumeMounts`). The operator does not know that pattern natively, so you
must replicate it by hand. Always pin `spec.image` explicitly. The bundled default of the operator
can be older than the already-migrated schema of your DB, and Pocket-ID refuses to start when the
schema is newer than the app version.

`security/pocket-id/operator/helmrelease.yaml` sets `instance.enabled: false`. The instance is a
standalone CR (`instance/pocketidinstance.yaml`), not chart-managed. The operator itself still
manages every `PocketIDOIDCClient` and `PocketIDUserGroup` CR across the cluster, wherever the
instance CR lives.

Read these live instance settings before you touch anything:

| Field                    | Value                                   | Why it matters                                              |
| ------------------------ | --------------------------------------- | ----------------------------------------------------------- |
| `image`                  | digest-pinned (`pocketidinstance.yaml`) | must be ≥ the DB's migrated schema, see above               |
| `ldap.userSearchFilter`  | `(objectClass=person)`                  | the default, so the `admin` of lldap is in scope, see below |
| `ldap.softDeleteUsers`   | `true`                                  | a user leaving the filter is disabled, not removed          |
| `ldap.adminGroupName`    | `lldap_admin`                           | membership here grants Pocket-ID admin                      |
| `metrics.enabled` / port | `true` / `9464`                         | scraped by the `pocket-id` ServiceMonitor in `instance/`    |

`security/pocket-id-operator` ships its own alert rules (`PocketIDOIDCClientRotationFailing` and
`PocketIDOIDCClientRotationOverdue` among them) and a ServiceMonitor, so a failing client-secret
rotation does alert.

### Groups: the CR name is not the group name

Three `PocketIDUserGroup` CRs exist. Each one has a `metadata.name` that differs
from the `spec.name` that apps match on:

| CR name (`kubectl get pocketidusergroup -n security`) | `spec.name` (what goes in the group list of an app) |
| ----------------------------------------------------- | --------------------------------------------------- |
| `app-admin`                                           | `app_admin`                                         |
| `app-ops`                                             | `app_ops`                                           |
| `app-users`                                           | `app_users`                                         |

The CR uses hyphens and the group uses underscores. A `TINYAUTH_APPS_*_GROUPS` or app-side group ACL
written with hyphens matches nobody, and it fails open or closed depending on the app. In contrast, the
`allowedUserGroups[].name` of a `PocketIDOIDCClient` references the CR name
(`app-admin`). The two conventions sit side by side, and it is easy to swap them.

## lldap wiring — the adoption gotcha

The `spec.ldap` block of Pocket-ID syncs by the LDAP `uuid` attribute
(`attributeMapping.userUniqueIdentifier`/`groupUniqueIdentifier: uuid`). This matches the
documented Pocket-ID example of lldap (`example_configs/pocket-id.md` upstream: bind DN
`cn=admin,ou=people,...`, not `uid=admin`; `uuid` for unique identifiers; `uid`/`mail`/
`givenName`/`sn`/`jpegPhoto`/`member`/`cn` for the rest).

Suppose Pocket-ID already has local (pre-LDAP) users or groups with the same username or name as their real
lldap counterparts. The sync then tries to `INSERT` a new row and collides on the `username`/`name`
UNIQUE constraint. Postgres aborts the transaction, and `SyncLdap` fails every cycle. The `ldap_id`
column on existing local rows is not proof of a real link. Pocket-ID fills it with the
username as a placeholder for purely local accounts.

The fix is to adopt in place. Do not delete and recreate. Query the real `uuid` of lldap for each user or group
via its GraphQL API (`POST /auth/simple/login` → bearer token → `POST /api/graphql` with
`{ users { id uuid email } }` / `{ groups { id displayName uuid } }`). Then run `UPDATE users/
user_groups SET ldap_id = '<real-uuid>' WHERE username/name = '<name>'` directly in Postgres. This causes zero
disruption, and passkeys, sessions and audit history all survive. If you delete and recreate, every real user
must register their passkey again.

The bootstrap `admin` account of lldap also gets synced if your `userSearchFilter` is the
default `(objectClass=person)`. Its `uid` is `admin`, which likely collides with the pre-existing local `admin` account of Pocket-ID.
Either exclude it (`(&(objectClass=person)(!(uid=admin)))`) or
adopt it the same way as real users (map its real lldap `uuid` in too) if you want it synced.
Watch for `softDeleteUsers: true` silently disabling an account whose `ldap_id` predates its exclusion
from the search filter. The account looks "removed from the directory" and gets soft-deleted.
If that happens, clear its stale `ldap_id` to `NULL` and re-enable it.

## Gating apps: tinyauth and envoy-oidc

`components/tinyauth` (Envoy Gateway `SecurityPolicy.extAuth` that points at the shared tinyauth
pod) is the standard way to gate an app at the edge. It gives one shared login and session across every
protected app (cookie on `.dcunha.io`), passkey via Pocket-ID plus lldap password fallback, and
per-app group ACLs via env vars. Apps with real user models (Immich, Grafana, Paperless, …) keep
their native `PocketIDOIDCClient` for in-app identity. tinyauth is a gate, not identity
propagation, and the two layer well.

`components/envoy-oidc` (`SecurityPolicy.oidc`, where Envoy does the OAuth flow itself with a per-app
session) is the other option, used per app against Pocket-ID. To see who carries it, run
`grep -rln 'components/envoy-oidc' kubernetes/apps`. Unlike tinyauth, it has no shared session
and no ACL env. Access is the `allowedUserGroups` of the `PocketIDOIDCClient` of the app.

These rules bite when you wire an app in (full walkthrough:
`.agents/skills/add-tinyauth-app/SKILL.md`):

- Every app ACL needs THREE keys since v5.1.0, not two:

    | Key                                    | Checked for              | If unset                  |
    | -------------------------------------- | ------------------------ | ------------------------- |
    | `TINYAUTH_APPS_<NAME>_OAUTH_WHITELIST` | OAuth email, first       | denies every OAuth user   |
    | `TINYAUTH_APPS_<NAME>_OAUTH_GROUPS`    | Pocket-ID session groups | allows any Pocket-ID user |
    | `TINYAUTH_APPS_<NAME>_LDAP_GROUPS`     | lldap password session   | allows any lldap user     |

    The whitelist is the trap. The v5.1.0 rules engine matches it against the OAuth email _before_
    the group check, and an empty whitelist is not "no filter". `CheckFilter` returns
    `ErrFilterEmpty`, which resolves to `EffectDeny`. An app that worked on v5.0.x locks every
    passkey user out on upgrade while LDAP password login keeps working, which looks like a
    Pocket-ID fault. Set it to the match-all regex `"/.*/"` so that the group lists stay the real gate:

    ```yaml
    TINYAUTH_APPS_<APP>_OAUTH_WHITELIST: "/.*/"
    TINYAUTH_APPS_<APP>_OAUTH_GROUPS: app_admin,app_ops
    TINYAUTH_APPS_<APP>_LDAP_GROUPS: app_admin,app_ops
    ```

    Group names use underscores (`app_admin`). See § Groups above. The two group keys exist
    because group checks are per login provider, and the same name works for both (Pocket-ID syncs
    groups from lldap).

    Correction for v5.1.3 (read 2026-08-24 in `internal/service/access_controls_rules.go`):
    an empty OAuth whitelist now returns `EffectAbstain`, not `EffectDeny`. Under the default
    `allow` policy that resolves to _allowed_, so the lockout described above no longer happens
    on its own. But `TINYAUTH_AUTH_ACLS_POLICY` is now set to `deny` here, and under `deny` an
    abstain resolves to denied. The `/.*/` whitelist is therefore still required on every ACL'd
    app, for the opposite reason than originally written.

- `TINYAUTH_AUTH_ACLS_POLICY: deny` (the default is `allow`). An app with no `TINYAUTH_APPS_*`
  entry at all abstains on `RuleUserAllowed` and is therefore denied, instead of admitting every
  authenticated user. This guardrail makes adding apps safe. The cost is that a new
  protected app is locked out until its ACL keys exist. This was verified safe before enabling:
  `IPAllowedRule` returns `EffectAllow` when no allow-list is configured
  (`access_controls_rules.go:265`), so the negated `if !Evaluate(RuleIPAllowed)` check in
  `proxy_controller.go:140` cannot lock everyone out.

    `deny` reaches further than the app ACLs, and this bites. `AuthService.IsEmailWhitelisted`
    (`auth_service.go:322`) evaluates the global `TINYAUTH_OAUTH_WHITELIST` through
    `policyEngine.EvaluateFunc`, and an unset whitelist returns `EffectAbstain`. Under `deny` that
    resolves to denied. This happens at the OAuth callback in `oauth_controller.go`, before any app ACL is
    consulted, so every Pocket-ID login fails with "The user with username &lt;email&gt; is not
    authorized to login", including the Immich login. A grep for `Evaluate(` misses this. The call is
    `EvaluateFunc`, and it is the only other caller in the tree.

    Therefore `TINYAUTH_OAUTH_WHITELIST: "/.*/"` is mandatory whenever the policy is `deny`.
    It does not loosen security. The `allowedUserGroups: app-users` of Pocket-ID on the tinyauth
    client already decides who can reach tinyauth at all, and per-app `TINYAUTH_APPS_*_GROUPS`
    decides which app they reach. The global whitelist is an email filter that this cluster does
    not use.

- `TINYAUTH_LABELPROVIDER: none` is deliberate. The label-provider auto-detect of v5.1.0 wants an
  in-cluster ServiceAccount token that is not mounted. If you leave it unset, tinyauth logs
  detection failures at boot. ACLs here come from `TINYAUTH_APPS_*` env, never from labels.
- ext_authz intercepts every external request on the route, not only browsers. Mobile apps,
  API tokens, and webhooks that hit `*.dcunha.io` break unless you exempt them via
  `TINYAUTH_APPS_<NAME>_PATH_ALLOW` regexes. Internal `svc.cluster.local` traffic never touches
  the gateway and is unaffected.
- Sessions live in sqlite on an emptyDir (`/data/tinyauth.db`; v5 has no `TINYAUTH_SECRET`,
  sessions are DB rows). Every tinyauth pod restart logs everyone out of every protected app.
  This is a deliberate trade-off for now: a restart is an instant cluster-wide session revocation. Sessions
  otherwise last `TINYAUTH_AUTH_SESSIONEXPIRY` (604800s = 7 days), which is also the revocation
  lag for a user disabled in lldap.
- The pod runs as the `tinyauth` user (1000) of the image with a read-only root filesystem. The
  sqlite DB and the resources dir live on the `/data` emptyDir. The signing-key secret is mounted
  `0440` so that `fsGroup: 1000` can read it. `0400` is root-only and breaks OIDC.

## Handing the app an authenticated session, not just a gate

By default tinyauth is a doorman. It proves that you can pass, and then the app has no idea who you are,
so an app with its own login shows that login anyway. Two mechanisms fix that. Which one you use
depends on what the app supports.

tinyauth always sets `Remote-User`, `Remote-Name`, `Remote-Email`, `Remote-Groups` and
`Remote-Sub` on the authenticated response (`proxy_controller.go:261-271`). But none of them
reach the backend unless the `headersToBackend` of the SecurityPolicy names them. That list is the
whole contract. `components/tinyauth/securitypolicy.yaml` carries `Authorization`, `Location`
and `Set-Cookie`. Add `Remote-*` there when an app that consumes them arrives.

For an app with no trusted-header mode at all, tinyauth can mint credentials instead:

```yaml
TINYAUTH_APPS_<APP>_RESPONSE_BASICAUTH_USERNAME: <user>
TINYAUTH_APPS_<APP>_RESPONSE_BASICAUTH_PASSWORDFILE: /secrets/oidc/<app>-basic-password
```

`proxy_controller.go:321-325` reads the password file and sets
`Authorization: Basic <base64>`, which overrides the echoed request `Authorization` from line 309.
This requires `Authorization` in `headersToBackend` (it is there). Confirmed present in v5.1.3:
`model.AppBasicAuth`, `config.go:328`.

No app uses this today (bazarr moved to `components/envoy-oidc`). The pattern: the own auth of the app is set to `basic`, the
password lives in the own 1Password item of the app as `TINYAUTH_BASIC_PASSWORD`, and the `tinyauth`
ExternalSecret pulls it with a second `dataFrom.extract` and renders it as `<app>-basic-password`.
The credential belongs to the app, and tinyauth only presents it.

Keep app credentials in the `artemis` vault. The `onepassword-connect` ClusterSecretStore serves
`artemis: 1`, `infrastructure: 2`, `frostlink: 3` by priority, so a bare `key: <name>` resolves
to the highest-priority vault that holds that title. A same-named item added to `artemis` silently
shadows one in `infrastructure`. Search every vault before you create an item
(`op item list --vault <v>` per vault, not only `artemis`).

The password file path says `oidc` and that is deliberate. The `tinyauth` Secret is mounted
wholesale at `/secrets/oidc` by the `persistence.oidc` entry, so every key in it lands there.
If you rename the mount, `TINYAUTH_OIDC_PRIVATEKEYPATH` moves and Immich's cached JWKS breaks. See
§ tinyauth is also an OIDC provider. Live with the name.

### bazarr: own auth deliberately off

envoy-oidc has no credential handoff, so with the own `basic` auth of bazarr on, users logged in twice
(Pocket-ID, then a browser popup). On 2026-09-29 the `auth.type` of bazarr was set to `null`, and users log
in once at Pocket-ID. The accepted cost: anything inside the cluster reaches the UI unauthenticated,
and the UI page embeds the API key, because `media` has no NetworkPolicy.

- `auth.type` is not in git. It lives in `config.yaml` on the PVC of bazarr. To turn it back on, use
  the API and do not edit the file: `POST /api/system/settings` with `X-API-KEY`,
  `settings-auth-type=form` (no popup) or `basic`, `settings-auth-username`, and
  `settings-auth-password=<plaintext>`. bazarr MD5-hashes it server-side
  (`bazarr/app/config.py:748`).
- Probes are safe either way. `/api/system/ping` is declared upstream as explicitly
  unauthenticated (`bazarr/api/system/ping.py`, no `@authenticate`). Auth guards only the UI
  blueprint catch-all in `bazarr/app/ui.py`.

## Sonarr v5 and Radarr v7: native OIDC, one user

Sonarr v5 (pre-release, from `5.0.0.2569`, Sonarr PR #8950) and Radarr v7 (pre-release, from
`7.0.0.10815`, Radarr PR #11927) have their own OIDC login (`<APP>__AUTH__METHOD: Oidc`). Both
are wired the same way. The notes below use the names of Sonarr, and the names of Radarr are the same with a
`RADARR` prefix (`RADARR_OIDC_USER_ID` on the `radarr` item, `radarr-oidc-credentials`).
Prowlarr has no OIDC. Do not copy this pattern to it.

- It admits exactly one user. `SONARR__AUTH__OIDCUSERIDENTIFIER` is matched against the `sub`
  claim, or the email when `email_verified` is true. Sonarr ignores group claims. The `allowedUserGroups` of the client decides who can reach the
  login at all. The value is the Pocket-ID user ID
  (the `sub`), kept as `SONARR_OIDC_USER_ID` on the `sonarr` 1Password item. gitleaks flags a
  literal UUID in the manifest as a generic API key. Recover it from `GET /api/users` with the
  `pocket-id-static-api-key` Secret.
- `SONARR__AUTH__REQUIRED` must be `Enabled`. Requests arrive through Envoy from a private
  address, so `DisabledForLocalAddresses` would skip the login entirely.
- `SONARR__SERVER__TRUSTEDNETWORKS` must hold the pod CIDR. By default Sonarr honors
  `X-Forwarded-Proto` only from loopback, so behind Envoy it builds an `http://` redirect
  URI and Pocket-ID rejects it ("redirect_uri ... is not registered"). This shows as a 500 on
  `/login/sso`.
- The API key is unaffected. `X-Api-Key` and `?apikey=` are separate schemes registered beside
  OIDC, so in-cluster callers (Prowlarr, seerr, the arr MCP tools, `refresh-series.sh`) keep
  working. `/ping` stays anonymous for the probes.
- An incomplete config falls back to Forms with a health warning, not an error. If the login page
  shows a username form, check the four `OIDC*` env vars and the `sonarr-oidc-credentials` Secret.
- "Correlation failed" on a later login is upstream issue #9099: the browser caches the `/login/sso` redirect.
  Clear the site cache.
- The callback is the ASP.NET default `/signin-oidc`. Sign-out returns to `/signout-callback-oidc`.

## The login flow is one visible page, by design

`TINYAUTH_OAUTH_AUTOREDIRECT: pocketid` skips the own provider-picker of tinyauth and sends the user
straight to Pocket-ID. The only login page that anyone sees is therefore the passkey prompt at
`id.dcunha.io`. Paired with `skipConsent: true` on the tinyauth `PocketIDOIDCClient`, there is no
consent screen either.

Auto-redirect does not remove the lldap password fallback. It fires only when the login
request carries a `redirect_uri` or `oidc_ticket` screen param, that is, when a protected app bounced you
(`frontend/src/pages/login-page.tsx`). If you visit `auth.dcunha.io` directly,
it still renders the full page with the username/password form. This is the break-glass path when
Pocket-ID is down. The same file calls `setIsOauthAutoRedirect(false)` on OAuth failure, so a
failed passkey hop also falls back to the form and does not loop.

Pocket-ID sees exactly one client for this whole path, named Artemis SSO (`clientID`
`tinyauth`). Every tinyauth-gated app is invisible to it, so the consent/authorize
screen names the gate, never the app you asked for. This is the direct consequence of
consolidating to one shared client, and it is why per-app authorization has to live in
`TINYAUTH_APPS_*`.

## tinyauth is also an OIDC provider

Since v5.1.0, tinyauth does not only _consume_ Pocket-ID. It also _issues_ OIDC to downstream apps.
Immich authenticates against tinyauth (`auth.dcunha.io`), not against Pocket-ID directly, via
`TINYAUTH_OIDC_CLIENTS_IMMICH_*`. So the login flow of Immich is
`Immich → tinyauth → Pocket-ID → lldap`, with the LDAP password form of tinyauth as an alternative
second hop. A `media/immich` `PocketIDOIDCClient` also exists. Do not assume from its presence
that Immich talks to Pocket-ID.

Two things will break it:

- The signing keys come from the `tinyauth` 1Password secret, mounted read-only at
  `/secrets/oidc` (`TINYAUTH_OIDC_PRIVATEKEYPATH` / `_PUBLICKEYPATH`). They are deliberately
  not on `/data`, which is an emptyDir. Keys that regenerate on every pod restart would
  invalidate every cached JWKS and break Immich login until clients refetched. If you move key
  storage, the new place must survive a restart.
- `TINYAUTH_OIDC_CLIENTS_IMMICH_TRUSTEDREDIRECTURIS` carries four entries, including the
  `app.immich:///oauth-callback` mobile deep link. If you drop it, only the phone app breaks, which
  is easy to miss when you test in a browser.

tinyauth itself is routed at `auth.dcunha.io` on `edge-gateway`. It has to be reachable
from wherever a protected app is reachable, including off-LAN. So is pocket-id (`id.dcunha.io`).

## Cross-namespace grants: ResourceSet, not per-namespace files

The `tinyauth` Service lives in `security`. Apps in other namespaces (`media`, etc.) need a
`ReferenceGrant` declared _in_ `security` before their `SecurityPolicy.extAuth` can reference it.
Gateway API requires the namespace that owns the resource to declare the grant, never the
consumer. Otherwise any namespace could grant itself access to anything.

The grants come from a single `ResourceSet` (`fluxcd.controlplane.io/v1`, from `flux-operator`, which is already
present in this cluster and confirmed working empirically) at
`security/tinyauth/app/resourceset.yaml`. `spec.inputs` is a flat list of namespaces. `spec.resources`
templates one `ReferenceGrant` per input via `<< inputs.namespace >>` syntax (not `{{ }}`, which is
reserved to avoid clashing with Helm). To add a new namespace, add one line to
`spec.inputs`. It is entirely inline, with no external template path and no per-namespace file, and you can test it
with `apply-ks` like everything else. One input line per namespace beats per-namespace files or nested Kustomizations, which you cannot
test with `apply-ks`.

Generated resources need an explicit `metadata.namespace` in the template. `ResourceSet`
does not inherit a default namespace for what it creates, unlike the `targetNamespace` of a Flux Kustomization.

The `ResourceSet` generates one `ReferenceGrant` per `spec.inputs` entry, named `<namespace>-grant`. Check the
inputs and do not trust a list here: `sed -n '/inputs:/,/resources:/p'
kubernetes/apps/security/tinyauth/app/resourceset.yaml`, or `kubectl get referencegrant -n
security`. To add the first app in a new namespace, add a line there and add the own
`SecurityPolicy` of the app. A missing grant shows as the `SecurityPolicy` sitting `Accepted=False` with a
`RefNotPermitted` reason, not as a login failure.

## Flux ordering: the operator installs the CRDs, so it goes first

`pocket-id-operator` must not depend on `pocket-id` (the instance). The instance applies a `PocketIDInstance` CR whose CRD the
HelmRelease of the operator installs, and nothing bootstraps those CRDs out-of-band in
`bootstrap/helmfile.d`. This is invisible on a warm cluster, but a cold rebuild deadlocks. The instance
cannot apply without the CRD, and the operator that would supply it waits behind the instance
going Ready. The graph is:

```text
pocket-id-operator  (no deps — installs the CRDs)
  └── pocket-id     (the PocketIDInstance CR)
  └── pocket-id-groups
        └── pocket-id-extclients
```

`security/tinyauth` also depends on `pocket-id-operator`, which is correct for the same reason,
because it applies a `PocketIDOIDCClient`.

## Forgejo admin is driven by the Pocket-ID `app_admin` group

The Forgejo OAuth2 source has `AdminGroup = app_admin` and `GroupClaimName = groups`, so on
every OIDC login Forgejo recomputes `is_admin` from the groups claim. That makes it a
demotion path, not only a promotion path. If the claim does not arrive, Forgejo sets
`is_admin = 0` and the next login undoes any manual promotion.

An empty `Scopes` field means that Forgejo never requests the `groups` scope and Pocket-ID never sends
the claim. A correct config reads `Scopes = ["groups"]` (Forgejo stores it as a JSON array).

Check it with:

```bash
ssh root@10.10.99.24 "sqlite3 /var/lib/forgejo/data/forgejo.db \
  \"SELECT json_extract(cfg,'\$.AdminGroup'), json_extract(cfg,'\$.GroupClaimName'), \
     json_extract(cfg,'\$.Scopes') FROM login_source;\""
```

Keep these two consequences in mind:

- If you remove yourself from `app_admin` in Pocket-ID, Forgejo demotes you at the next login.
  The local `administrator` account (`is_admin=1`, `login_type=0`) is the break-glass path.
- This lives in the database of Forgejo, not in `app.ini`. `ansible/roles/forgejo` cannot manage it
  and cannot prevent a recurrence, because an auth source is API/UI state.
