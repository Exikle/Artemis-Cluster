# Commit Style — Artemis-Cluster

Commit hygiene and message format are in `~/.agents/AGENTS.md` § Commit Hygiene and § Commit
Message Format. The always-on rules are in `AGENTS.md` § The rules that apply to every turn. This
file covers only the sequence, and why each step exists.

## Two-identity signing model

| Identity               | How commits land on main            | Signed by                        |
| ---------------------- | ----------------------------------- | -------------------------------- |
| Exikle (Dixon D'Cunha) | Push directly to main after testing | Exikle's personal GPG key        |
| Renovate / dusk-bot    | Squash-merged PR                    | git.dcunha.io Instance (SSH key) |

A squash merge always creates a new server-side commit, which cannot be signed by Exikle's local
key. So Exikle **never** goes through a PR merge for their own work. PRs are for Renovate only.

## The sequence

**0. Suspend first — two calls, root and target** (`AGENTS.md` rule 1 wins). `apply-ks` does not
suspend for you.

```bash
just kube suspend-ks flux-system artemis-cluster
just kube suspend-ks <ns> <ks-name>
```

Order does not matter going in, and both are idempotent.

Why the root matters: `apply-ks` writes uncommitted local edits with
`field-manager=kustomize-controller`. Children reconcile on their own interval, so one firing
mid-session silently reverts those edits to what is in git. Across a dependency chain, a child on
a stale fetch can re-apply an old revision and cascade into deleted CRs and PVCs. The data
survives — CNPG `Database` and kopiur defaults retain it — but the objects do not.

**Nothing errors if you forget.** The apply succeeds, then a controller reverts it minutes later,
and it reads as the change never having landed.

**1.** Write the changes in your worktree (`AGENTS.md` rule 7). `just wt new` branches from the
**local** `main`, which falls behind as Renovate merges land — and `apply-ks` from a stale tree
silently reverts those bumps live. Pull first. `<main>` below is the main checkout, the parent of
`.worktrees/` (`dirname "$(git rev-parse --path-format=absolute --git-common-dir)"`):

```bash
git -C <main> pull --ff-only
just wt new <type>/<slug>
```

**2.** Apply to the live cluster from the worktree: `just kube apply-ks <ns> <ks-name>`.

**3.** Wait for **explicit user confirmation** that it works. Not a running pod — the user's word.

**4.** Commit in the worktree (global § Commit Hygiene), then land it on `main` through the main
checkout. The `agent-main-checkout` hk step blocks only agent _commits_ there, not merges or
pushes. Your shell is in the worktree, so name the main checkout explicitly:

```bash
git -C <worktree> fetch origin
git -C <worktree> rebase origin/main          # only if main moved; re-test if it did
git -C <main> status --short --branch         # must be on main, clean
git -C <main> pull --ff-only
git -C <main> merge --ff-only <type>/<slug>
git -C <main> push origin main
```

`just wt rm <type>/<slug>` after step 5; it refuses unless the branch is an ancestor of `main`.

**5.** Wait for the `Push OCI Artifact (Tekton)` run on your commit to go **green**, then
`just kube sync-flux ocirepo flux-system` until the artifact carries **your commit**:

```bash
kubectl get ocirepository -n flux-system flux-system \
  -o jsonpath='{.status.artifact.metadata.org\.opencontainers\.image\.revision}'
# main@sha1:<git sha> — compare against `git rev-parse HEAD`
```

Use that metadata field, not `.status.artifact.revision`. The latter is `main@sha256:<OCI digest>`
— not the git sha, so it can never match your commit — and watching it merely _change_ is racy in
both directions: if an earlier sync already pulled the new artifact, the digest never changes again
and the check waits forever on work that is already done.

Name `flux-system` in the sync. The bare `just kube sync-flux ocirepo` force-annotates **every**
OCIRepository in the cluster when step 5 cares about exactly one.

Then resume — **root first, then the target**, as two calls:

```bash
just kube resume-ks flux-system artemis-cluster
just kube resume-ks <ns> <ks-name>
```

`resume-ks` refuses to wake a child while the root is still suspended, and warns if anything else
is left suspended when it finishes.

Do not resume before the artifact is rebuilt. The OCIRepository is built by CI, so a resume
immediately after `git push` applies the **pre-commit** revision and silently reverts what you
just landed. `✔ applied revision` alone proves nothing — confirm the live object still carries
your field.

## Squash rules

- One commit per distinct feature or fix.
- Pre-merge corrections (wrong port, typo, image tag, ExternalSecret mismatch) → amend the local
  commit before pushing.
- Post-push discoveries → a new commit on main, always.

## Renovate PR auto-merge

Renovate PRs squash-merge on their own. The manual-merge command and its batching trap are in
`.agents/references/renovate.md` § Merging a batch, which wins.
