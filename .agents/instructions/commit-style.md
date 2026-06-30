# Commit Style — Artemis-Cluster

## Two-identity signing model

| Identity               | How commits land on main            | Signed by                        |
| ---------------------- | ----------------------------------- | -------------------------------- |
| Exikle (Dixon D'Cunha) | Push directly to main after testing | Exikle's personal GPG key        |
| Renovate / dusk-bot    | Squash-merged PR                    | git.dcunha.io Instance (SSH key) |

Squash merge always creates a new server-side commit — it cannot be signed by Exikle's local key. So Exikle **never** goes through a PR merge for their own work. PRs are for Renovate only.

---

## Exikle workflow — always test before committing

This repo has no staging cluster. `main` reconciles directly to production.

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

5. After push: `just kube sync ocirepo`

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
