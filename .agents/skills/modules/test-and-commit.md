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

## Commit and push directly to main (Exikle's own work)

Exikle never merges via PR — squash merge creates a server-side commit that gets instance-signed, not Exikle-signed. Push directly so commits carry Exikle's personal GPG signature.

After user confirms:

```bash
# Stage specific files — never git add . or git add -A
git add kubernetes/apps/<namespace>/<app>/ kubernetes/apps/<namespace>/kustomization.yaml

# Verify staged diff — check for secrets, debug output, unintended files
git diff --staged

# Commit (signed locally by Exikle's key)
git commit -m "feat(<namespace>): deploy <app>"

# Push directly to main
git push origin main

# Sync cluster after push
just kube sync ocirepo
```

---

## Fix / convention correction

```bash
# Stage only the changed manifests
git add kubernetes/apps/<namespace>/<app>/

# Verify
git diff --staged

# Commit
git commit -m "fix(<namespace>): bring <app> manifests to convention"

# Push directly to main
git push origin main
just kube sync ocirepo
```

---

## Branch naming (for reference / Renovate PRs only)

```text
feat/<namespace>-<app>       # new deployments
fix/<namespace>-<app>        # bug fixes or convention corrections
chore/<scope>                # updates, housekeeping
refactor/<namespace>-<app>   # restructuring without behaviour change
```
