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

0. **`just kube apply-ks` suspends for you** — the root Kustomization
   (`artemis-cluster`) and the target child, before it applies anything. You do
   not need to `flux suspend` by hand any more, and it is idempotent, so
   applying repeatedly in one session is fine.

    Why it does this, because it is not obvious and the manual version kept
    losing the race: `apply-ks` writes uncommitted local edits to the cluster
    with `field-manager=kustomize-controller`. Child Kustomizations reconcile on
    their own independent interval, and **suspending the root does not pause
    them** — so if a child's controller fires mid-session (its normal interval,
    or a Renovate merge landing), it silently reverts those edits back to
    whatever is already in git, because it does not know about the in-progress
    test. Worse, if edits span a dependency chain (e.g. an instance plus the
    operator that manages it), a child reconciling against a stale fetch can
    re-apply an old revision, recreate resources the new state already replaced,
    and cascade into deleted CRs/PVCs — even though the underlying data survives,
    retained by CNPG `Database`/kopiur defaults. See the pocket-id-operator
    migration incident (2026-07-14).

    If you suspend anything else by hand during a session, `just kube resume-ks`
    in step 5 picks it up too — it resumes whatever is suspended, cluster-wide.

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

5. After push: wait for the `Push Artifact` run on your commit to go **green**,
   then `just kube sync ocirepo` until the `flux-system` digest actually
   changes, then `just kube resume-ks` (children first, root last, in one pass).

    Do not resume before the artifact is rebuilt. The OCIRepository is built by
    CI, so a resume immediately after `git push` applies the **pre-commit**
    revision and silently reverts what you just landed. `✔ applied revision`
    alone proves nothing — confirm the live object still carries your field.

**Never commit or push until the user explicitly confirms the live deployment works.**

---

## Renovate PR auto-merge

Renovate PRs squash-merge on their own. The manual-merge command, and the trap that lost three
PRs on 2026-08-19 (**never queue `merge_when_checks_succeed` on more than one PR at a time**), are
in `.agents/references/renovate.md` § Merging a batch.

---

## Message length

**Keep bodies short — a few lines at most.** Record the non-obvious trap or why a
choice was made. Not a session narrative, not a list of everything verified. If it
reads like a report, cut it. Long rationale goes in `.agents/references/` or a
Forgejo issue, not in `git log`.

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
