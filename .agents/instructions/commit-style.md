# Commit Style — Artemis-Cluster

Universal commit hygiene and the semantic message format are in the global agent context. The
always-on rules are in `AGENTS.md` § The seven rules. This file covers only the sequence, and why
each step exists.

## Two-identity signing model

| Identity               | How commits land on main            | Signed by                        |
| ---------------------- | ----------------------------------- | -------------------------------- |
| Exikle (Dixon D'Cunha) | Push directly to main after testing | Exikle's personal GPG key        |
| Renovate / dusk-bot    | Squash-merged PR                    | git.dcunha.io Instance (SSH key) |

A squash merge always creates a new server-side commit, which cannot be signed by Exikle's local
key. So Exikle **never** goes through a PR merge for their own work. PRs are for Renovate only.

## The sequence

**0. Suspend first — two calls, root and target.** `apply-ks` does not suspend for you.

```bash
just kube suspend-ks flux-system artemis-cluster
just kube suspend-ks <ns> <ks-name>
```

Order does not matter going in, and both are idempotent.

Why the root matters, because it is not obvious: `apply-ks` writes uncommitted local edits to the
cluster with `field-manager=kustomize-controller`. Child Kustomizations reconcile on their own
independent interval, and **suspending the root does not pause them** — so if a child's controller
fires mid-session (its normal interval, or a Renovate merge landing), it silently reverts those
edits to whatever is already in git. Worse, if edits span a dependency chain, a child reconciling
against a stale fetch can re-apply an old revision, recreate resources the new state already
replaced, and cascade into deleted CRs and PVCs. The underlying data survives — CNPG `Database`
and kopiur defaults retain it — but the objects do not. See the pocket-id-operator incident
(2026-07-14).

**Nothing errors if you forget.** The apply succeeds, then a controller reverts it minutes later,
and it reads as the change never having landed.

**1.** Write the changes locally.

**2.** Apply to the live cluster: `just kube apply-ks <ns> <ks-name>`.

**3.** Wait for **explicit user confirmation** that it works. Not a running pod — the user's word.

**4.** Stage specific files by name, `git diff --staged` to check for secrets and debug output,
commit with a one-line subject, push to `main`.

**5.** Wait for the `Push Artifact` run on your commit to go **green**, then
`just kube sync-flux ocirepo` until the `flux-system` digest actually changes, then resume —
**root first, then the target**, as two calls:

```bash
just kube resume-ks flux-system artemis-cluster
just kube resume-ks <ns> <ks-name>
```

`resume-ks` refuses to wake a child while the root is still suspended, and warns if anything else
is left suspended when it finishes.

Do not resume before the artifact is rebuilt. The OCIRepository is built by CI, so a resume
immediately after `git push` applies the **pre-commit** revision and silently reverts what you
just landed. `✔ applied revision` alone proves nothing — confirm the live object still carries
your field.

## Squash rules

- One commit per distinct feature or fix.
- Pre-merge corrections (wrong port, typo, image tag, ExternalSecret mismatch) → amend the local
  commit before pushing.
- Post-push discoveries → a new commit on main, always.

## Renovate PR auto-merge

Renovate PRs squash-merge on their own. The manual-merge command, and the trap that lost three
PRs on 2026-08-19 (**never queue `merge_when_checks_succeed` on more than one PR at a time**), are
in `.agents/references/renovate.md` § Merging a batch.
