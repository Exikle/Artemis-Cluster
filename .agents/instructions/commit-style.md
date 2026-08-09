# Commit Style — Artemis-Cluster

Universal commit hygiene (no `Co-Authored-By`, no `--no-verify`, stage by name, `git diff --staged`
before committing, never force-push `main`) and the semantic message format are in the global agent
context. This file covers only what is specific to this repo.

## Two-identity signing model

| Identity               | How commits land on main            | Signed by                        |
| ---------------------- | ----------------------------------- | -------------------------------- |
| Exikle (Dixon D'Cunha) | Push directly to main after testing | Exikle's personal GPG key        |
| Renovate / dusk-bot    | Squash-merged PR                    | git.dcunha.io Instance (SSH key) |

Squash merge always creates a new server-side commit — it cannot be signed by Exikle's local key. So Exikle **never** goes through a PR merge for their own work. PRs are for Renovate only.

---

## Exikle workflow — always test before committing

This repo has no staging cluster. `main` reconciles directly to production.

0. **Suspend both the root Kustomization AND every child Kustomization you're
   about to touch before any live testing session**:
   `flux suspend kustomization artemis-cluster` plus
   `flux suspend kustomization <ks-name> -n <ns>` for each Kustomization whose
   manifests you're editing (e.g. `pocket-id`, `pocket-id-operator`). Child
   Kustomizations reconcile on their own independent interval — suspending
   only the root does **not** pause them. `just kube apply-ks` applies
   uncommitted local edits directly to the cluster with
   `field-manager=kustomize-controller` — if a child's own controller
   reconciles mid-session (its normal interval, or a Renovate merge landing),
   it silently reverts those uncommitted edits back to whatever's already in
   git, since it doesn't know about the in-progress test. Worse, if edits span
   a dependency chain (e.g. an instance + the operator that manages it), a
   child reconciling against a stale fetch mid-session can re-apply an old
   revision, recreate resources the new state already replaced, and cascade
   into deleted CRs/PVCs even though the underlying data survives (retained
   by CNPG `Database`/kopiur defaults) — see the pocket-id-operator
   migration incident (2026-07-14). Resume every suspended Kustomization
   (children first, then root) once the session's changes are committed and
   pushed (step 5) — resume the root **once**, in a single pass, rather than
   piecemeal per-child, to avoid re-triggering the same race.
1. Write changes locally
2. Apply to live cluster: `just kube apply-ks <ns> <ks-name>`
3. Wait for **explicit user confirmation** that it works
4. Stage specific files, commit, and push directly to `main`:

    ```bash
    git add <specific files>
    git diff --staged          # verify — check for secrets, debug output
    git commit -m "feat(scope): ..."
    git push origin main
    ```

5. After push: `just kube sync ocirepo`, then resume every child Kustomization
   suspended in step 0, then `flux resume kustomization artemis-cluster` last

**Never commit or push until the user explicitly confirms the live deployment works.**

---

## Renovate PR auto-merge

Renovate PRs auto-merge via squash. To manually trigger:

```bash
FORGEJO_TOKEN=$(op read 'op://kubernetes/forgejo/FORGEJO_ADMIN_TOKEN') && \
curl -s -X POST "https://git.dcunha.io/api/v1/repos/exikle/Artemis-Cluster/pulls/<PR_NUMBER>/merge" \
  -H "Authorization: Bearer $FORGEJO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"Do":"squash","merge_when_checks_succeed":true,"delete_branch_after_merge":true}'
```

Squash lands as `title (#N)` on main, signed by git.dcunha.io Instance.

---

## Squash rules

- Squash by logical change — one commit per distinct feature/fix
- Pre-merge corrections (wrong port, typo, image tag, ExternalSecret mismatch) → amend the local commit before pushing
- Post-push discoveries → new commit on main, always

## Branch naming (only needed for Renovate triage reference)

```text
feat/cortex-agentmemory
fix/media-sonarr-client
chore/flux-update
```
