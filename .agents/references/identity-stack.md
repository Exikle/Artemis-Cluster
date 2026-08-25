# Identity Stack — lldap → Pocket-ID → tinyauth

How this cluster's identity chain fits together, and which auth mechanism to reach for. Verified
against the live cluster 2026-08-24.

Live versions: pocket-id `v2.14.0`, tinyauth `v5.1.3`, lldap `2026-05-05-alpine-rootless`.

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

Three consumers, and it matters which one an app is on:

| Mechanism                       | Who is on it                                                                                                                                                                                                           |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Native `PocketIDOIDCClient`     | `cortex/hermes`, `default/immich`, `default/komga`, `media/autobrr`, `media/bookboss`, `media/paperless`, `media/shelfmark`, `observability/grafana`, `security/continuwuity`, `security/forgejo`, `security/tinyauth` |
| `components/tinyauth` edge gate | `media/bazarr` — **still the only one**                                                                                                                                                                                |
| tinyauth's own OIDC provider    | Immich (see § tinyauth is also an OIDC provider)                                                                                                                                                                       |

`kubectl get pocketidoidcclient -A` is ground truth for the first row; the second is
`kubectl get securitypolicy -A` (ignore `cortex/litellm`, which is a CORS policy, not extAuth).

**No password ever reaches Pocket-ID.** lldap has real password login (its own web UI at
`ldap.dcunha.io`, used for self-service profile management, plus the service-account bind
credential Pocket-ID uses to read the directory) — but Pocket-ID is exclusively passkey/WebAuthn
("Pocket ID only supports passwordless authentication", upstream docs), even for LDAP-synced
users. The LDAP sync only provisions _who_ the users/groups are; it is not a login mechanism.
Password fallback exists solely because tinyauth binds lldap itself (`TINYAUTH_LDAP_*` env in
`security/tinyauth/app/helmrelease.yaml`) — its login page offers "Login with Pocket-ID"
(passkey) plus a username/password form validated directly against lldap, same directory, same
groups.

## Pocket-ID: operator-managed, not app-template

`security/pocket-id/instance/` holds a `PocketIDInstance` CR — the operator
(`aclerici38/pocket-id-operator`) owns the Deployment/Service/HTTPRoute directly, not an
app-template HelmRelease. Postgres access uses the shared CNPG cluster via cert-manager mTLS
(`postgres-pocket-id-cert` + `postgres-server-ca`, mounted via `spec.podTemplate.spec.volumes` +
`persistence.extraVolumeMounts` since the operator doesn't know that pattern natively — you have
to replicate it by hand). **Always pin `spec.image` explicitly** — the operator's own bundled
default can be older than your DB's already-migrated schema, and Pocket-ID refuses to start on a
schema-newer-than-app-version mismatch.

`security/pocket-id/operator/helmrelease.yaml` sets `instance.enabled: false` — the instance is a
standalone CR (`instance/pocketidinstance.yaml`), not chart-managed. The operator itself still
manages every `PocketIDOIDCClient`/`PocketIDUserGroup` CR across the cluster regardless of where
the instance CR lives.

Live instance settings worth knowing before touching anything:

| Field                    | Value                    | Why it matters                                                |
| ------------------------ | ------------------------ | ------------------------------------------------------------- |
| `image`                  | `v2.14.0`, digest-pinned | must be ≥ the DB's migrated schema, see above                 |
| `ldap.userSearchFilter`  | `(objectClass=person)`   | the **default** — lldap's `admin` is in scope, see below      |
| `ldap.softDeleteUsers`   | `true`                   | a user leaving the filter is disabled, not removed            |
| `ldap.adminGroupName`    | `lldap_admin`            | membership here grants Pocket-ID admin                        |
| `metrics.enabled` / port | `true` / `9464`          | exposed on the Service and **scraped by nothing** — see below |

**The `security` namespace has no `ServiceMonitor`/`VMServiceScrape` at all.** pocket-id's `:9464`
is dead-ended, and `security/pocket-id-operator` ships 13 alert rules whose metrics therefore
never exist — `PocketIDOIDCClientRotationFailing` and `PocketIDOIDCClientRotationOverdue` among
them. Client-secret rotation can fail silently and forever. Details:
`.agents/references/observability.md` § Scrape coverage.

### Groups: the CR name is not the group name

Three `PocketIDUserGroup` CRs exist, and every one of them has a `metadata.name` that differs
from the `spec.name` apps actually match on:

| CR name (`kubectl get pocketidusergroup -n security`) | `spec.name` — what goes in an app's group list |
| ----------------------------------------------------- | ---------------------------------------------- |
| `app-admin`                                           | `app_admin`                                    |
| `app-ops`                                             | `app_ops`                                      |
| `app-users`                                           | `app_users`                                    |

Hyphens in the CR, **underscores in the group**. A `TINYAUTH_APPS_*_GROUPS` or app-side group ACL
written with hyphens matches nobody and fails open or closed depending on the app. A
`PocketIDOIDCClient`'s `allowedUserGroups[].name`, by contrast, references the **CR** name
(`app-admin`) — the two conventions sit side by side and are easy to swap.

## lldap wiring — the adoption gotcha

Pocket-ID's `spec.ldap` block syncs by the LDAP `uuid` attribute
(`attributeMapping.userUniqueIdentifier`/`groupUniqueIdentifier: uuid`), matching lldap's own
documented Pocket-ID example (`example_configs/pocket-id.md` upstream: bind DN
`cn=admin,ou=people,...` — **not** `uid=admin`, `uuid` for unique identifiers, `uid`/`mail`/
`givenName`/`sn`/`jpegPhoto`/`member`/`cn` for the rest).

If Pocket-ID already has local (pre-LDAP) users/groups with the same username/name as their real
lldap counterparts, the sync tries to `INSERT` a new row and collides on the `username`/`name`
UNIQUE constraint — Postgres aborts the transaction, `SyncLdap` fails every cycle. The `ldap_id`
column on existing local rows is **not** proof of a real link; Pocket-ID populates it with the
username as a placeholder for purely-local accounts.

**Fix: adopt in place, don't delete-and-recreate.** Query lldap's real `uuid` for each user/group
via its GraphQL API (`POST /auth/simple/login` → bearer token → `POST /api/graphql` with
`{ users { id uuid email } }` / `{ groups { id displayName uuid } }`), then `UPDATE users/
user_groups SET ldap_id = '<real-uuid>' WHERE username/name = '<name>'` directly in Postgres. Zero
disruption — passkeys, sessions, audit history all survive. Deleting and recreating would force
passkey re-registration for every real user.

**lldap's own bootstrap `admin` account will get synced too** if your `userSearchFilter` is the
default `(objectClass=person)` — its `uid` is `admin`, which likely collides with Pocket-ID's own
pre-existing local `admin` account. Either exclude it (`(&(objectClass=person)(!(uid=admin)))`) or
adopt it the same way as real users (map its real lldap `uuid` in too) if you want it synced.
Watch for `softDeleteUsers: true` silently disabling an account whose `ldap_id` predates being
excluded from the search filter — it'll look "removed from the directory" and get soft-deleted;
clear its stale `ldap_id` to `NULL` and re-enable if that happens.

## Gating apps: tinyauth (envoy-oidc removed 2026-07-15)

`components/tinyauth` (Envoy Gateway `SecurityPolicy.extAuth` pointing at the shared tinyauth
pod) is the standard way to gate an app at the edge: one shared login/session across every
protected app (cookie on `.dcunha.io`), passkey via Pocket-ID plus lldap password fallback, and
per-app group ACLs via env vars. Apps with real user models (Immich, Grafana, Paperless, …) keep
their native `PocketIDOIDCClient` for in-app identity — tinyauth is a gate, not identity
propagation, and the two layer fine.

`components/envoy-oidc` (`SecurityPolicy.oidc`, Envoy doing the OAuth flow itself with a per-app
session) was deleted 2026-07-15 — it never gained a single consumer; every OIDC app used native
app OIDC instead, and tinyauth covers the edge-gating role. Recoverable from git history if a
per-app-isolated-session need ever materializes.

Rules that bite when wiring an app in (full walkthrough:
`.agents/skills/add-tinyauth-app/SKILL.md`):

- **Every app ACL needs THREE keys since v5.1.0**, not two:

    | Key                                    | Checked for              | If unset                    |
    | -------------------------------------- | ------------------------ | --------------------------- |
    | `TINYAUTH_APPS_<NAME>_OAUTH_WHITELIST` | OAuth email, **first**   | **denies every OAuth user** |
    | `TINYAUTH_APPS_<NAME>_OAUTH_GROUPS`    | Pocket-ID session groups | allows any Pocket-ID user   |
    | `TINYAUTH_APPS_<NAME>_LDAP_GROUPS`     | lldap password session   | allows any lldap user       |

    The whitelist is the trap. The v5.1.0 rules engine matches it against the OAuth email _before_
    the group check, and an empty whitelist is not "no filter" — `CheckFilter` returns
    `ErrFilterEmpty`, which resolves to `EffectDeny`. An app that worked on v5.0.x locks every
    passkey user out on upgrade while LDAP password login keeps working, which reads like a
    Pocket-ID fault. Set it to the match-all regex `"/.*/"` so the group lists stay the real gate:

    ```yaml
    TINYAUTH_APPS_BAZARR_OAUTH_WHITELIST: "/.*/"
    TINYAUTH_APPS_BAZARR_OAUTH_GROUPS: app_admin,app_ops
    TINYAUTH_APPS_BAZARR_LDAP_GROUPS: app_admin,app_ops
    ```

    Group names use **underscores** (`app_admin`) — see § Groups above. The two group keys exist
    because group checks are per login provider, and the same name works for both (Pocket-ID syncs
    groups from lldap).

    **Correction for v5.1.3** (read 2026-08-24 in `internal/service/access_controls_rules.go`):
    an empty OAuth whitelist now returns `EffectAbstain`, not `EffectDeny`. Under the default
    `allow` policy that resolves to _allowed_, so the lockout described above no longer happens
    on its own. But `TINYAUTH_AUTH_ACLS_POLICY` is now set to `deny` here, and under `deny` an
    abstain resolves to **denied** — so the `/.*/` whitelist is still required on every ACL'd
    app, for the opposite reason than originally written.

- **`TINYAUTH_AUTH_ACLS_POLICY: deny`** (default is `allow`). An app with no `TINYAUTH_APPS_*`
  entry at all abstains on `RuleUserAllowed` and is therefore denied, instead of admitting every
  authenticated user. This is the guardrail that makes adding apps safe; the cost is that a new
  protected app is locked out until its ACL keys exist. Verified safe before enabling:
  `IPAllowedRule` returns `EffectAllow` when no allow-list is configured
  (`access_controls_rules.go:265`), so the negated `if !Evaluate(RuleIPAllowed)` check in
  `proxy_controller.go:140` cannot lock everyone out.

    **`deny` reaches further than the app ACLs, and this bites.** `AuthService.IsEmailWhitelisted`
    (`auth_service.go:322`) evaluates the **global** `TINYAUTH_OAUTH_WHITELIST` through
    `policyEngine.EvaluateFunc`, and an unset whitelist returns `EffectAbstain`. Under `deny` that
    resolves to denied — at the OAuth callback in `oauth_controller.go`, before any app ACL is
    consulted — so **every** Pocket-ID login fails with "The user with username &lt;email&gt; is not
    authorized to login", including Immich's. Grepping for `Evaluate(` misses this; the call is
    `EvaluateFunc`, and it is the only other caller in the tree.

    Therefore `TINYAUTH_OAUTH_WHITELIST: "/.*/"` is **mandatory** whenever the policy is `deny`.
    It is not a security loosening: Pocket-ID's own `allowedUserGroups: app-users` on the tinyauth
    client already decides who may reach tinyauth at all, and per-app `TINYAUTH_APPS_*_GROUPS`
    decides which app they reach. The global whitelist is an email filter that this cluster does
    not use. Hit and fixed 2026-08-24.

- **`TINYAUTH_LABELPROVIDER: none` is deliberate.** v5.1.0's label-provider auto-detect wants an
  in-cluster ServiceAccount token that is not mounted; leaving it unset makes tinyauth log
  detection failures at boot. ACLs here come from `TINYAUTH_APPS_*` env, never from labels.
- **ext_authz intercepts every external request on the route**, not just browsers — mobile apps,
  API tokens, and webhooks hitting `*.dcunha.io` break unless exempted via
  `TINYAUTH_APPS_<NAME>_PATH_ALLOW` regexes. Internal `svc.cluster.local` traffic never touches
  the gateway and is unaffected.
- **Sessions live in sqlite on an emptyDir** (`/data/tinyauth.db`; v5 has no `TINYAUTH_SECRET`,
  sessions are DB rows) — every tinyauth pod restart logs everyone out of every protected app.
  Deliberate trade-off for now: restart = instant cluster-wide session revocation. Sessions
  otherwise last `TINYAUTH_AUTH_SESSIONEXPIRY` (604800s = 7 days), which is also the revocation
  lag for a user disabled in lldap.
- **The pod runs as root** (`runAsNonRoot: false`, `runAsUser: 0`) with
  `readOnlyRootFilesystem: false`. A genuine deviation from the repo default security context —
  do not "fix" it without testing; the sqlite DB and the resources dir both live under `/data`.

## Handing the app an authenticated session, not just a gate

By default tinyauth is a doorman: it proves you may pass, then the app has no idea who you are,
so an app with its own login shows it anyway. Two mechanisms fix that, and which one you use
depends on what the app supports.

tinyauth always sets `Remote-User`, `Remote-Name`, `Remote-Email`, `Remote-Groups` and
`Remote-Sub` on the authenticated response (`proxy_controller.go:261-271`), **but none of them
reach the backend unless named in the SecurityPolicy's `headersToBackend`** — that list is the
whole contract. `components/tinyauth/securitypolicy.yaml` carries `Authorization`, `Location`
and `Set-Cookie`; add `Remote-*` there when an app that consumes them arrives.

For an app with no trusted-header mode at all, tinyauth can mint credentials instead:

```yaml
TINYAUTH_APPS_<APP>_RESPONSE_BASICAUTH_USERNAME: <user>
TINYAUTH_APPS_<APP>_RESPONSE_BASICAUTH_PASSWORDFILE: /secrets/oidc/<app>-basic-password
```

`proxy_controller.go:321-325` reads the password file and sets
`Authorization: Basic <base64>`, overriding the echoed request `Authorization` from line 309.
Requires `Authorization` in `headersToBackend` (it is). Confirmed present in v5.1.3 —
`model.AppBasicAuth`, `config.go:328`.

**bazarr is the live example.** Its own auth is set to `basic` with username `bazarr`, and the
password lives in the **`bazarr`** 1Password item (vault `artemis`) as `TINYAUTH_BASIC_PASSWORD`.
The `tinyauth` ExternalSecret pulls it with a second `dataFrom.extract` and renders it as the
`bazarr-basic-password` key — the credential belongs to the app, tinyauth only presents it.

Keep app credentials in the `artemis` vault. The `onepassword-connect` ClusterSecretStore serves
`artemis: 1`, `infrastructure: 2`, `frostlink: 3` **by priority**, so a bare `key: <name>` resolves
to the highest-priority vault holding that title — a same-named item added to `artemis` silently
shadows one in `infrastructure`. Search **every** vault before creating an item
(`op item list --vault <v>` per vault, not just `artemis`). Users log in once at Pocket-ID and
never see bazarr's login page, while bazarr is no longer naked to anything that reaches it past
the gateway.

Three things about that setup which are not obvious:

- **The password file path says `oidc` and that is deliberate.** The `tinyauth` Secret is mounted
  wholesale at `/secrets/oidc` by the `persistence.oidc` entry, so every key in it lands there,
  including this one. Renaming the mount would move `TINYAUTH_OIDC_PRIVATEKEYPATH` and break
  Immich's cached JWKS — see § tinyauth is also an OIDC provider. Live with the name.
- **bazarr's `auth.type` is not in git.** It lives in `config.yaml` on bazarr's PVC. A volume
  restore reverts it to `null`, which fails **open** — bazarr becomes reachable without its own
  auth to anything already past the tinyauth gate. Set it back via the API rather than by hand:
  `POST /api/system/settings` with `X-API-KEY`, `settings-auth-type=basic`,
  `settings-auth-username`, `settings-auth-password=<plaintext>`; bazarr MD5-hashes it server-side
  (`bazarr/app/config.py:748`). Editing `config.yaml` directly races bazarr's own config writer.
- **Probes are safe.** `/api/system/ping` is declared upstream as an explicitly unauthenticated
  endpoint (`bazarr/api/system/ping.py`, no `@authenticate`); basic auth only guards the UI
  blueprint catch-all in `bazarr/app/ui.py`. Enabling it does not break the liveness/readiness
  probes that target it.

## The login flow is one visible page, by design

`TINYAUTH_OAUTH_AUTOREDIRECT: pocketid` skips tinyauth's own provider-picker and sends the user
straight to Pocket-ID, so the only login page anyone sees is the passkey prompt at
`id.dcunha.io`. Paired with `skipConsent: true` on the tinyauth `PocketIDOIDCClient`, there is no
consent screen either.

**Auto-redirect does not remove the lldap password fallback.** It only fires when the login
request carries a `redirect_uri` or `oidc_ticket` screen param — i.e. when you were bounced from
a protected app (`frontend/src/pages/login-page.tsx`). Visiting `auth.dcunha.io` **directly**
still renders the full page with the username/password form, which is the break-glass path when
Pocket-ID is down. The same file calls `setIsOauthAutoRedirect(false)` on OAuth failure, so a
failed passkey hop also falls back to the form rather than looping.

Pocket-ID sees exactly one client for this whole path, named **Artemis SSO** (`clientID`
`tinyauth`). Bazarr and every other gated app are invisible to it, so the consent/authorize
screen names the gate, never the app you asked for. That is the direct consequence of
consolidating to one shared client, and it is why per-app authorization has to live in
`TINYAUTH_APPS_*`.

## tinyauth is also an OIDC provider

Since v5.1.0 tinyauth does not only _consume_ Pocket-ID — it _issues_ OIDC to downstream apps.
**Immich authenticates against tinyauth (`auth.dcunha.io`), not against Pocket-ID directly**, via
`TINYAUTH_OIDC_CLIENTS_IMMICH_*`. So Immich's login flow is
`Immich → tinyauth → Pocket-ID → lldap`, with tinyauth's LDAP password form as an alternative
second hop. A `default/immich` `PocketIDOIDCClient` also exists; do not assume from its presence
that Immich talks to Pocket-ID.

The one thing that will break it:

- **Signing keys come from the `tinyauth` 1Password secret**, mounted read-only at
  `/secrets/oidc` (`TINYAUTH_OIDC_PRIVATEKEYPATH` / `_PUBLICKEYPATH`). They are deliberately
  **not** on `/data`, which is an emptyDir — keys regenerated on every pod restart would
  invalidate every cached JWKS and break Immich login until clients refetched. If you move key
  storage, it must be to something that survives a restart.
- `TINYAUTH_OIDC_CLIENTS_IMMICH_TRUSTEDREDIRECTURIS` carries four entries, including the
  `app.immich:///oauth-callback` mobile deep link. Dropping it breaks the phone app only, which
  is easy to miss when testing in a browser.

tinyauth itself is routed at `auth.dcunha.io` on **`external-gateway`** — it has to be reachable
from wherever a protected app is reachable, including off-LAN.

## Cross-namespace grants: ResourceSet, not per-namespace files

The `tinyauth` Service lives in `security`; apps in other namespaces (`media`, etc.) need a
`ReferenceGrant` declared _in_ `security` before their `SecurityPolicy.extAuth` can reference it
— Gateway API requires the grant to be declared by the resource-owning namespace, never the
consumer (otherwise any namespace could grant itself access to anything).

Two earlier approaches were tried and abandoned before landing on the current one:

1. **One `ReferenceGrant` file per consuming namespace**, manually maintained in
   `security/tinyauth/app/grants/`. Worked, but needed a new file per namespace.
2. **A nested Flux `Kustomization`** (with its own independent `spec.targetNamespace: security`,
   exploiting the fact that a Kustomization _object's_ `targetNamespace` field is just a string to
   Kustomize's namespace transformer — it isn't itself rewritten the way a Deployment or Service
   would be) triggered once per namespace, folded into that namespace's own `namespace.yaml`.
   Worked, zero new files per app, but every new namespace still needed hand-writing a templated
   Kustomization block, and nested Kustomizations only resolve against the _real_ Flux git/OCI
   source — they can't be tested via `apply-ks` before a push, unlike everything else in this repo.

**Current: a single `ResourceSet`** (`fluxcd.controlplane.io/v1`, from `flux-operator` — already
present in this cluster, confirmed working empirically) at
`security/tinyauth/app/resourceset.yaml`. `spec.inputs` is a flat list of namespaces; `spec.resources`
templates one `ReferenceGrant` per input via `<< inputs.namespace >>` syntax (not `{{ }}` — that's
reserved to avoid clashing with Helm). Adding a new namespace is a one-line addition to
`spec.inputs`, entirely inline, no external template path, no per-namespace file, testable with
`apply-ks` like everything else. This is the pattern to keep using — don't reintroduce either of
the earlier two.

Generated resources need an **explicit `metadata.namespace`** in the template — `ResourceSet`
does not inherit a default namespace for what it creates, unlike a Flux Kustomization's
`targetNamespace`.

Live state: `spec.inputs` is `[{namespace: media}]`, producing exactly one `ReferenceGrant`
(`security/media-grant`). Adding the first app in a new namespace means adding a line there
**and** the app's own `SecurityPolicy` — a missing grant surfaces as the `SecurityPolicy` sitting
`Accepted=False` with a `RefNotPermitted` reason, not as a login failure.

## Flux ordering: the operator installs the CRDs, so it goes first

`security/pocket-id/ks.yaml` used to have `pocket-id-operator` depend on `pocket-id` (the
instance). That is backwards: the instance applies a `PocketIDInstance` CR whose CRD the
operator's HelmRelease installs, and those CRDs are **not** bootstrapped out-of-band in
`bootstrap/helmfile.d`. Invisible on a warm cluster, but a cold rebuild deadlocks — the instance
cannot apply without the CRD, and the operator that would supply it is gated behind the instance
going Ready. Commit `244a2623c` preserved the edge believing it was a CRD guarantee.

Corrected 2026-08-24. The graph is now:

```text
pocket-id-operator  (no deps — installs the CRDs)
  └── pocket-id     (the PocketIDInstance CR)
  └── pocket-id-groups
        └── pocket-id-extclients
```

`security/tinyauth` also depends on `pocket-id-operator`, which is correct for the same reason —
it applies a `PocketIDOIDCClient`.

## The manifests are comment-free

`security/tinyauth/app/helmrelease.yaml` previously carried inline prose for the whitelist rule,
the label provider, and the OIDC key paths, violating `yaml-conventions.md` § No Comments in
Manifests. Removed 2026-08-24 — all three rationales live in this file. Do not put them back.
