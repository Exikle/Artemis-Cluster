---
name: flux-validate
description: Validate and render cluster manifests locally before committing — build the kustomization, diff against the live cluster, and catch schema and substitution errors that would otherwise fail reconciliation. Use for "validate manifests", "render kustomization", "flux diff", or a pre-commit check on a manifest change. Scoped to the Artemis cluster.
---

# Skill: Flux Validate

Validate and diff Flux manifests offline before you commit, with `flate` (already available through `mise`).

Always validate before you commit. `main` reconciles directly to production.

## Quick Render (single kustomization)

```bash
just kube render-ks <namespace> <ks-name>
```

This runs `flate build ks --namespace <namespace> --output yaml <ks-name>` and prints the rendered manifests. It catches schema errors, missing references, and HelmRelease value mistakes.

The root (`render-ks flux-system flux-system`) is the exception. flux-operator generates it, so
flate cannot see it. The recipe runs `flux build kustomization` against the live root instead,
which needs the cluster.

The `<ks-name>` is `metadata.name` from the `ks.yaml` of the app, not the directory name.

## Full Test Suite

```bash
flate test all
```

This prints one result per resource. The exit code is non-zero on any failure or blocked resource.

`.mise/config.toml` sets `FLATE_PATH` (the `kubernetes/apps` entry path), `FLATE_SUPPLY` and
`FLATE_DISABLE_CHART_DIGEST_TRACKING`, so flate needs no flags here. Run it through `mise`.
The digest setting mirrors the `DisableChartDigestTracking` gate on helm-controller in
`flux-instance`. If you change one, change the other.

flate 0.7 cannot read objects that are not in git. This cluster syncs from an OCIRepository, so
flate cannot build the `flux-system` source itself, and it cannot read Secrets that 1Password
creates. `scripts/flate-supply.yaml` holds placeholders for them. When a render stops on
`<kind> <ns>/<name> not found`, add that object to the file.
`--allow-missing-secrets` no longer exists.

## Diff Against the Live Cluster

```bash
just kube diff-ks <namespace> <ks-name>
```

This is read-only. It renders locally with `flate`, then runs `kubectl diff --server-side`, which is a server-side
**dry-run apply**. The API server does its own defaulting before it compares. Defaulted fields
never show up as drift. A hand-rolled render-vs-live comparison cannot avoid that. `dyff` renders the output,
so a change appears as a field path rather than a line number.

Exit codes: **0** means no differences. **1** means differences found _or_ the render failed. You tell the two apart
by the output, not by the code. Drift ends on `WARN Differences found`, and a bad ks name
ends on `flate error:`.

Run this check _before_ `suspend-ks` + `apply-ks`, to see what a change would actually
move. It is not the same as `flate diff` below. This one compares local against **the cluster**,
and `flate diff` compares local against **main**.

## Diff Against Main (changed-only)

```bash
git worktree add --detach /tmp/artemis-baseline main
flate diff ks --path-orig /tmp/artemis-baseline/kubernetes/apps
git worktree remove /tmp/artemis-baseline
```

Changed-only mode reconciles only the subtree that a change touches. It is fast even on large repos.

## List All Kustomizations

```bash
flate get ks
```

## Build a Specific HelmRelease

```bash
flate build hr --namespace <namespace> --output yaml <helmrelease-name>
```

## Validate Workflow (pre-commit checklist)

1. Run `just kube render-ks <ns> <ks>` to render the changed kustomization.
2. Review the output for unexpected changes.
3. Run `just kube diff-ks <ns> <ks>` to see what the change would actually move in the cluster.
4. Run `flate test all` for the full suite.
5. If the tests pass, continue with `.agents/skills/modules/test-and-commit.md`. The sequence is in
   `.agents/instructions/commit-style.md` § The sequence: suspend root and target, apply, wait for the
   user, commit, wait for the artifact, resume.

## Notes

- A Secret that an ExternalSecret creates is not readable offline. Where a `postBuild.substituteFrom` or `valuesFrom` needs it, flate blocks the resource until `scripts/flate-supply.yaml` supplies a placeholder.
- This cluster does not use SOPS ciphertext (all secrets come from 1Password ExternalSecret), so you never need decryption offline.
- OCI sources (app-template, and others) need network access to pull charts. Run with the network available.
