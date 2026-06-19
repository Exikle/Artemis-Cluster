# Skill: Flux Validate

Validate and diff Flux manifests offline before committing, using `flate` (already available via `mise`).

**Always validate before creating a PR.** `main` reconciles directly to production.

## Quick Render (single kustomization)

```bash
mise exec -- just kube render-local-ks <namespace> <ks-name>
```

This runs `flate build ks --namespace <namespace> --output yaml <ks-name>` and prints the rendered manifests. Catches schema errors, missing references, and HelmRelease value mistakes.

The `<ks-name>` is `metadata.name` from the app's `ks.yaml`, not the directory name.

## Full Test Suite

```bash
mise exec -- flate test all --path ./kubernetes
```

Runs pytest-style `PASS`/`FAIL`/`SKIPPED` per resource. Exit code non-zero on any failure.

Add `--allow-missing-secrets` to skip ExternalSecret-backed secret refs (1Password secrets don't exist offline):

```bash
mise exec -- flate test all --path ./kubernetes --allow-missing-secrets
```

## Diff Against Main (changed-only)

```bash
git worktree add /tmp/artemis-baseline main
mise exec -- flate diff ks --path ./kubernetes --path-orig /tmp/artemis-baseline/kubernetes
git worktree remove /tmp/artemis-baseline
```

Changed-only mode reconciles only the subtree a change touches — fast even on large repos.

## List All Kustomizations

```bash
mise exec -- flate get ks --path ./kubernetes
```

## Build a Specific HelmRelease

```bash
mise exec -- flate build hr --namespace <namespace> --output yaml <helmrelease-name>
```

## Validate Workflow (pre-commit checklist)

1. `mise exec -- just kube render-local-ks <ns> <ks>` — render the changed kustomization
2. Review output for unexpected changes
3. `mise exec -- flate test all --path ./kubernetes --allow-missing-secrets` — full suite
4. If tests pass: apply to live cluster, wait for user confirmation, then commit

## Notes

- `flate` handles ExternalSecrets gracefully: if the Secret has a declared producer (ExternalSecret), it marks it `Ready / "skipped"` instead of failing. No need for `--allow-missing-secrets` in most cases.
- SOPS ciphertext is NOT used in this cluster (all secrets via 1Password ExternalSecret), so decryption is never needed offline.
- OCI sources (app-template, etc.) need network access to pull charts — run with network available.
