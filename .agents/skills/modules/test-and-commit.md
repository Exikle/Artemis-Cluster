# Module: Test and Commit

Uses the `tea` CLI for PR operations against Forgejo (`gh` does not work here). All other tools
(`just`, `crane`) resolve directly from within the Artemis-Cluster directory — no `mise exec --`
prefix needed.

**The commit/apply/resume sequence is defined once in `.agents/instructions/commit-style.md`.**
This module shows the commands in the order a deploy session runs them; where the two disagree,
`commit-style.md` wins. It is always-loaded, this module is not.

---

## Test live (always before committing)

```bash
# Look up the ks name first — it is the metadata.name in ks.yaml, not always <app>
grep "^  name:" kubernetes/apps/<namespace>/<app>/ks.yaml

# Apply using the exact name from above
just kube apply-ks <namespace> <ks-name>

```

Then verify the rollout. Use the `-ops` MCP k8s tools for this (`pods_list_in_namespace`,
`resources_get` on the HelmRelease, `pods_log`) rather than shelling out — see
`cluster-conventions.md` § Cluster Inspection. The `kubectl` equivalents, if MCP is unavailable:

```bash
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
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
```

Then finish the sequence — **do not stop at `sync ocirepo`**:

```bash
# 1. Wait for the `Push Artifact` CI run on YOUR commit to go green.
#    Resuming before the artifact is rebuilt applies the pre-commit revision
#    and silently reverts what you just landed.

# 2. Force the flux-system source to pick up the new artifact — repeat until
#    the digest actually changes.
just kube sync ocirepo

# 3. Resume everything `apply-ks` suspended (root + children, and anything you
#    suspended by hand during the session).
just kube resume-ks
```

`just kube apply-ks` suspends the root `artemis-cluster` Kustomization **and** the target child.
A session that ends at step 2 leaves Flux suspended cluster-wide — nothing reconciles until
someone notices. `✔ applied revision` alone proves nothing; confirm the live object still carries
your field. Full rationale: `.agents/instructions/commit-style.md` steps 0 and 5.

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
```

Then the same post-push sequence as above: wait for `Push Artifact` green →
`just kube sync ocirepo` until the digest changes → `just kube resume-ks`.

---

## Branch naming (for reference / Renovate PRs only)

```text
feat/<namespace>-<app>       # new deployments
fix/<namespace>-<app>        # bug fixes or convention corrections
chore/<scope>                # updates, housekeeping
refactor/<namespace>-<app>   # restructuring without behaviour change
```
