# Module: Test and Commit

The suspend, apply, confirm, commit, artifact-wait and resume sequence is defined once, in
`.agents/instructions/commit-style.md` § The sequence. Follow it from there. This module does not
restate it. This module adds only what is specific to a skill-driven session.

Edit in a worktree. Before the first edit, run `just wt new <type>/<slug>` (`AGENTS.md` rule 7).

---

## Before step 2 of the sequence

```bash
# The ks name is metadata.name in ks.yaml, not always <app>
grep "^  name:" kubernetes/apps/<namespace>/<app>/ks.yaml

# Render offline, then see what the change would move in the live cluster
just kube render-ks <namespace> <ks-name>
just kube diff-ks <namespace> <ks-name>
```

`flux-validate` covers both in detail.

## Verifying the rollout (after `apply-ks`)

For read-only inspection, use the `-ops` MCP k8s tools. List the tools and match on the server and
tool portion (`.agents/instructions/tooling.md` § MCP servers). Look for the pod list, the resource
get on the HelmRelease, and the pod log tools. These `kubectl` commands do the same:

```bash
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl describe helmrelease <app> -n <namespace>
```

Wait for the explicit confirmation of the user before you commit. A running pod is not confirmation. The word of the user is.

## Staging and message

Stage specific files only. Then run `git diff --staged`:

```bash
git add kubernetes/apps/<namespace>/<app>/ kubernetes/apps/<namespace>/kustomization.yaml
```

- New app: `feat(<namespace>): deploy <app>`
- Convention fix: `fix(<namespace>): bring <app> manifests to convention`

After the push, finish the sequence in `commit-style.md` step 5 and resume, root first. If a session
stops before the resume, Flux stays suspended.

Pull requests are for Renovate only (`commit-style.md` § Two-identity signing model).
