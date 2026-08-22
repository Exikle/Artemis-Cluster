# Identity Stack — lldap → Pocket-ID → tinyauth

How this cluster's identity chain fits together, and which auth mechanism to reach for. Verified
against the live cluster 2026-08-21.

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

## The manifests carry comments; this file is where they belong

`security/tinyauth/app/helmrelease.yaml` currently has inline explanatory comments for the
whitelist rule, the label provider, and the OIDC key paths. That violates
`yaml-conventions.md` § No Comments in Manifests. All three rationales are now written above —
the comments can be deleted from the manifest without losing anything.
