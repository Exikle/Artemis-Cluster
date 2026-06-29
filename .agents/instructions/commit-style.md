# Commit Style — Artemis-Cluster

## Workflow — always test before committing

This repo has no staging cluster. `main` reconciles directly to production.

1. Write changes locally
2. Apply to live cluster: `just kube apply-ks <ns> <ks-name>`
3. Wait for **explicit user confirmation** that it works
4. Create branch, commit, push, open PR using mcp-forgejo (repo: `exikle/Artemis-Cluster`, base: `main`).

5. Enable auto-merge via the Forgejo API directly (mcp-forgejo merge tool does NOT support `merge_when_checks_succeed`):

    ```bash
    FORGEJO_TOKEN=$(op read 'op://kubernetes/forgejo/FORGEJO_ADMIN_TOKEN') && \
    curl -s -X POST "https://git.dcunha.io/api/v1/repos/exikle/Artemis-Cluster/pulls/<PR_NUMBER>/merge" \
      -H "Authorization: Bearer $FORGEJO_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"Do":"rebase","merge_when_checks_succeed":true,"delete_branch_after_merge":true}'
    ```

    Rebase merge preserves the original locally-signed commits. Squash creates a new unsigned commit server-side.

6. Switch back to main and delete **local** branch only (Forgejo deletes the remote after merge). Do not wait for the merge — it will happen automatically when checks pass:

    ```bash
    git checkout main && git branch -d <branch>
    ```

7. After merge: `just kube sync ocirepo`

**Never commit or push until the user explicitly confirms the live deployment works.**

## Squash Rules

- Squash by logical change — one commit per distinct feature/fix
- Pre-merge corrections (wrong port, typo, image tag, ExternalSecret mismatch) → squash into original commit
- Post-merge discoveries → new commit on a new PR, always

## PR Branch Naming

```text
feat/cortex-agentmemory
fix/media-sonarr-client
chore/flux-update
```

Scope to namespace when relevant.
