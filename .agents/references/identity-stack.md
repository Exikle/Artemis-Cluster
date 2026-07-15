# Identity Stack — lldap → Pocket-ID → tinyauth / envoy-oidc

How this cluster's identity chain fits together, and which auth mechanism to reach for. Built
2026-07-14/15 migrating pocket-id to an operator-managed instance, wiring lldap in as the LDAP
source, and standing up tinyauth as a shared forward-auth service (bazarr as the first consumer).

## The chain

```
lldap (security ns)  →  Pocket-ID (security ns, auth.dcunha.io)  →  app-level auth
  directory: users,        OIDC provider, passkey-only login.       one of:
  groups, passwords         Syncs users/groups FROM lldap.          - native app OIDC client
  (self-service only)       Never verifies lldap passwords —        - components/envoy-oidc
                             Pocket-ID is passwordless for           - components/tinyauth
                             every account, LDAP-synced or not.
```

**No password ever reaches Pocket-ID.** lldap has real password login (its own web UI at
`lldap.dcunha.io`, used for self-service profile management, plus the service-account bind
credential Pocket-ID uses to read the directory) — but Pocket-ID is exclusively passkey/WebAuthn
("Pocket ID only supports passwordless authentication", upstream docs), even for LDAP-synced
users. The LDAP sync only provisions _who_ the users/groups are; it is not a login mechanism.

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

## Choosing envoy-oidc vs tinyauth

Both live under Envoy Gateway's `SecurityPolicy` CRD but are structurally different features:

|                                         | `components/envoy-oidc`                                                  | `components/tinyauth`                                                                                                |
| --------------------------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| Mechanism                               | `SecurityPolicy.oidc` — Envoy does the full OAuth flow itself            | `SecurityPolicy.extAuth` (ext_authz) — Envoy asks an external service yes/no                                         |
| Session                                 | Per-app, independent cookie per `SecurityPolicy`                         | Shared across every tinyauth-protected app (one cookie, parent domain)                                               |
| Dependency                              | None beyond Envoy + Pocket-ID                                            | Adds the tinyauth pod to the request path (mitigated by `failOpen: false`)                                           |
| Per-app access control                  | `PocketIDOIDCClient.allowedUserGroups` — clean CRD, free with the client | `TINYAUTH_APPS_<NAME>_OAUTH_GROUPS` env var — must be set explicitly, defaults to allow-any-authenticated if omitted |
| Can gate an app with zero built-in auth | Yes — Envoy intercepts before the backend                                | Yes — same capability, not a differentiator                                                                          |

**Default to `envoy-oidc`** for a single standalone app — fewer moving parts, no extra failure
domain, and per-app group scoping comes for free with the `PocketIDOIDCClient` CR. **Reach for
tinyauth** specifically when you want one login to cover multiple apps (no repeated OAuth
redirects moving between them), or need tinyauth's richer policy engine (IP allow/block, path
rules, LDAP-direct fallback) that Envoy's native OIDC doesn't expose at all.

Full walkthrough for wiring a new app into tinyauth: `.agents/skills/add-tinyauth-app/SKILL.md`.

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
