# Module: Test and Commit

Uses `tea` CLI (v0.14.1, installed at `~/.local/bin/tea`) for PR operations against Forgejo.
All other tools (`just`, `crane`) resolve directly from within the Artemis-Cluster directory — no `mise exec --` prefix needed.

---

## Test live (always before committing)

```bash
# Look up the ks name first — it is the metadata.name in ks.yaml, not always <app>
grep "^  name:" kubernetes/apps/<namespace>/<app>/ks.yaml

# Apply using the exact name from above
just kube apply-ks <namespace> <ks-name>

# Verify pod is running
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>

# Inspect the HelmRelease for errors
kubectl describe helmrelease <app> -n <namespace>
```

**Wait for explicit user confirmation that the deployment works before proceeding.**

Never commit until the user says so.

---

## Create PR and merge (new deployments)

After user confirms:

```bash
# Create branch first — commits belong on the branch, not main
git checkout -b feat/<namespace>-<app>

# Stage specific files — never git add . or git add -A
git add kubernetes/apps/<namespace>/<app>/ kubernetes/apps/<namespace>/kustomization.yaml

# Verify staged diff — check for secrets, debug output, unintended files
git diff --staged

# Commit
git commit -m "feat(<namespace>): deploy <app>"

# Push and open PR via tea
git push -u origin feat/<namespace>-<app>
tea pulls create --title "feat(<namespace>): deploy <app>" --head feat/<namespace>-<app> --base main

# Auto-merge squash — tea doesn't support merge_when_checks_succeed, use API
FORGEJO_TOKEN=$(op read "op://kubernetes/forgejo/FORGEJO_ADMIN_TOKEN")
curl -s -X POST "https://git.dcunha.io/api/v1/repos/exikle/Artemis-Cluster/pulls/<number>/merge" \
  -H "Authorization: token $FORGEJO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"Do":"squash","merge_when_checks_succeed":true,"delete_branch_after_merge":true}'

# Return to main and delete local branch — Forgejo deletes the remote after merge
# Do NOT verify file contents after checkout — the revert to main state is expected
git checkout main && git branch -d feat/<namespace>-<app>

# Sync cluster after merge
just kube sync ocirepo
```

---

## Create PR and merge (fixes / convention corrections)

```bash
# Create branch
git checkout -b fix/<namespace>-<app>

# Stage only the changed manifests
git add kubernetes/apps/<namespace>/<app>/

# Verify
git diff --staged

# Commit
git commit -m "fix(<namespace>): bring <app> manifests to convention"

# Push and open PR via tea
git push -u origin fix/<namespace>-<app>
tea pulls create --title "fix(<namespace>): bring <app> manifests to convention" --head fix/<namespace>-<app> --base main

# Auto-merge squash — use PR number from tea output above
FORGEJO_TOKEN=$(op read "op://kubernetes/forgejo/FORGEJO_ADMIN_TOKEN")
curl -s -X POST "https://git.dcunha.io/api/v1/repos/exikle/Artemis-Cluster/pulls/<number>/merge" \
  -H "Authorization: token $FORGEJO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"Do":"squash","merge_when_checks_succeed":true,"delete_branch_after_merge":true}'

# Return to main and delete local branch — Forgejo deletes the remote after merge
# Do NOT verify file contents after checkout — the revert to main state is expected
git checkout main && git branch -d fix/<namespace>-<app>
just kube sync ocirepo
```

---

## Branch naming

```text
feat/<namespace>-<app>       # new deployments
fix/<namespace>-<app>        # bug fixes or convention corrections
chore/<scope>                # updates, housekeeping
refactor/<namespace>-<app>   # restructuring without behaviour change
```
