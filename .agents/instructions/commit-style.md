# Commit Style — Artemis-Cluster

## Workflow — always test before committing

This repo has no staging cluster. `main` reconciles directly to production.

1. Write changes locally
2. Apply to live cluster: `just kube apply-ks <ns> <ks-name>`
3. Wait for **explicit user confirmation** that it works
4. Create branch, commit, push, open PR
5. Enable auto-merge: `PATH="$HOME/.local/share/mise/shims:$PATH" gh pr merge --auto --squash <PR-URL>`
6. After merge: `just kube sync-git`

**Never commit or push until the user explicitly confirms the live deployment works.**

## Squash Rules

- Squash by logical change — one commit per distinct feature/fix
- Pre-merge corrections (wrong port, typo, image tag, ExternalSecret mismatch) → squash into original commit
- Post-merge discoveries → new commit on a new PR, always

## Commit Message Format

Semantic prefix scoped to namespace:

```
feat(cortex): deploy agentmemory
fix(media): correct sonarr download client path
chore: update flux-instance to v2.5.1
docs: update CLAUDE.md hardware section
refactor(observability): split vmagent into separate ks
```

- Title-only is fine for small changes
- Explain WHY in the body only when genuinely non-obvious
- No `Co-Authored-By` trailer — ever
- No `--no-verify` — fix the hook instead

## Staging Rules

- Always stage specific files by name — never `git add .` or `git add -A`
- Run `git diff --staged` before committing — check for secrets, debug output, unintended files
- For public commits: no emails, usernames, private tracker names, or forwarded ports

## Undoing Commits

**Unpublished commit** (not yet pushed): `git reset HEAD~1` to unstage, or `git reset --hard HEAD~1` to discard entirely.

**Published commit** (already on origin/main): always use `git revert <sha>` — creates a new commit that undoes the change. Never force-push main.

```bash
git revert <sha>          # undo a single commit
git revert <sha1>..<sha2> # undo a range (oldest first)
```

Do not waste tokens re-explaining what went wrong — just revert and move on.

## PR Branch Naming

```
feat/cortex-agentmemory
fix/media-sonarr-client
chore/flux-update
```

Scope to namespace when relevant.
