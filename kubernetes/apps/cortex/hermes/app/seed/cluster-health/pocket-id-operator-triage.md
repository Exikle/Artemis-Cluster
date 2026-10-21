# Pocket-ID operator triage

Namespace `security` is on the do-not-touch list in `SKILL.md` Step 3. Neither class below is auto-fixable.

## Operator CrashLoop: version-skew halt (seen 2026-08-19, cleared)

Operator v0.13.1 halts on purpose when it sees an unsupported pocket-id release (log line `Pocket-id version is unsupported by this operator; halting`, with `detectedVersion` and `firstUnsupportedVersion`). It exits 1 on every restart, so `restartCount` climbs steadily (498 restarts over ~6 days) and `LeaderElection` events repeat about once a minute. A transient CrashLoop plateaus instead. Deleting the pod does nothing: every restart hits the same gate. The pocket-id workload stays `1/1 Running` and needs no restart. Side effect: the `pocket-id-extclients` Kustomization fails its health check because the `PocketIDOIDCClient` CRs stay `InProgress`.

Operator-side fix: upgrade the operator to a version that supports the installed pocket-id, or pin pocket-id to a release the operator supports (`latestTestedVersion` appears in the operator log). The operator has since been upgraded (v0.14.3, then v0.15.0).

## PocketIDOIDCClientPKCESupported (config gap, not a crash)

Annotation: `The PocketIDOIDCClient security/<name> supports PKCE but has it disabled. Set spec.pkceEnabled: true to enable it.` The operator pod is healthy; the CR has `spec.pkceEnabled: false`. The fix is a Flux/values edit that sets it to true; the alert clears after the operator next reconciles. Report which client, how long it has fired, and that the operator is healthy.

Closed for all four clients: forgejo (2026-09-14), tinyauth (2026-09-18), bookboss (2026-09-20), continuwuity (2026-10-16 04:00Z). A newly onboarded OIDC client can raise this alert again; the fix is the same.

## Recurrence log (open cases only)

Format and rules are in `SKILL.md` § Documented cases. No open Pocket-ID case at 2026-10-21. Full history (24 entries) is archived in `/opt/data/workspace/cluster-health/archive/pocket-id-operator-triage.full.md`.
