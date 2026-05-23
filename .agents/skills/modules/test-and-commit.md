# Module: Test and Commit

Uses `tea` (Forgejo CLI) for all PR operations — not `gh`. All tools (`just`, `tea`, `crane`) resolve directly from within the Artemis-Cluster directory — no `mise exec --` prefix needed.

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

# Push and open PR via tea (Forgejo)
git push -u origin feat/<namespace>-<app>
tea pulls create --title "feat(<namespace>): deploy <app>" --head feat/<namespace>-<app> --base main

# Enable auto-merge squash — use the PR number from the output above
tea pulls merge <number> --style squash

# Return to main and delete local branch
git checkout main && git branch -d feat/<namespace>-<app>

# Sync cluster after merge
just kube sync-git
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

# Push and PR
git push -u origin fix/<namespace>-<app>
tea pulls create --title "fix(<namespace>): bring <app> manifests to convention" --head fix/<namespace>-<app> --base main

# Auto-merge squash
tea pulls merge <number> --style squash

# Clean up
git checkout main && git branch -d fix/<namespace>-<app>
just kube sync-git
```

---

## Branch naming

```text
feat/<namespace>-<app>       # new deployments
fix/<namespace>-<app>        # bug fixes or convention corrections
chore/<scope>                # updates, housekeeping
refactor/<namespace>-<app>   # restructuring without behaviour change
```
