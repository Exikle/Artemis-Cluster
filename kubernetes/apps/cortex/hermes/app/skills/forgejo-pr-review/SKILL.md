---
name: forgejo-pr-review
description: "Daily review of every open PR in the Forgejo exikle org. Auto-merges dependency bumps that pass the 2 forgejo CI checks (labeler + konflate) and have no breaking-change markers; flags the rest. Notifies via chaski."
version: 2.0.0
author: Artemis
license: MIT
platforms: [linux]
metadata:
    hermes:
        tags: [Forgejo, Pull-Requests, CI/CD, Automation, Merge]
        related_skills: []
---

# Forgejo Daily PR Review

You are running on a daily schedule (09:00) to clean up the Forgejo org at `https://git.dcunha.io`. Goal: auto-merge dependency bumps that are obviously safe, and surface everything else as a clear list for human review.

## Auth

The `FORGEJO_PAT` env var holds a personal access token with `repo` and `write:repository` scopes (read PRs, write merge). Use it via `-H "Authorization: token $FORGEJO_PAT"`. Never echo the token. If it is unset, abort and notify via chaski (route `warning`) — do not retry.

## Step 1 — Enumerate repos

`exikle` is a **user account**, not an org. List every repo owned by the user:

```bash
curl -s -H "Authorization: token $FORGEJO_PAT" \
  'https://git.dcunha.io/api/v1/users/exikle/repos?limit=50' \
  | python3 -c "import sys,json; [print(r['name']) for r in json.load(sys.stdin)]"
```

Pagination: if `Link` header contains `rel="next"`, follow it until exhausted.

Skip these regardless of state:

- `exikle/containers` and any repo that is purely a CI/CD template farm (no PRs ever land there from humans).
- `exikle/homepage` and other personal-website repos — operator reviews those manually.

## Step 2 — List open PRs per repo

For each repo, fetch open PRs:

```bash
curl -s -H "Authorization: token $FORGEJO_PAT" \
  "https://git.dcunha.io/api/v1/repos/exikle/${REPO}/pulls?state=open&limit=50" \
  | python3 -m json.tool
```

For each PR, capture: `number`, `title`, `user.username`, `head.ref`, `mergeable`, `mergeable_state`, `draft`.

## Step 3 — Classify each PR

Three buckets. Apply in order.

### 3a — Always skip (do not flag)

- `draft: true` — the author knows it's not ready.
- PRs whose source repo has PRs disabled (e.g. `Exikle/fingerjoin` returns 404 on `/pulls` despite the repo existing — just record this in the summary and move on).

### 3b — Auto-merge if ALL of these hold

1. **Forgejo CI: both `Konflate` and `Labeler` checks succeeded.** Use `GET /repos/exikle/{repo}/commits/{sha}/status` — overall `state` must be `success`. If either check is missing, pending, or failed, downgrade to 3c (flag).
2. **Mergeable.** `mergeable` field is `true` and `mergeable_state` is `clean` or `unstable` (or `null` — Forgejo returns `null` for repos that haven't computed it yet, treat as mergeable if the combined CI status is success). `dirty` or `blocked` → flag.
3. **No merge conflicts** (covered by 3b.2).
4. **No human disapproval.** Check reviews: `GET /repos/exikle/{repo}/pulls/{index}/reviews` — there must be no review with `state: "REQUEST_CHANGES"` that hasn't been dismissed. `APPROVED` and `COMMENTED` are fine.
5. **No breaking change markers in the title.** Renovate and dusk-bot use Conventional Commits — `feat(...)!:` or `fix(...)!:` (with the bang) means breaking. `BREAKING CHANGE:` in the body footer also counts.
6. **Title type is one of:** `feat(container):`, `fix(container):`, `chore(container):`, `chore(deps):`, `feat(deps):`, `fix(deps):`, or any other commit type where the body shows a pure version-pin or image-tag change with no other code edits. If the diff touches more than one file or the changes aren't a pure version pin, flag.
7. **Diff is small and mechanical.** `GET /repos/exikle/{repo}/pulls/{index}/files` — total additions + deletions across all files should be ≤ 20 lines. Image-tag bumps are typically 1 line; if it's bigger, flag.

**No human approval required.** Renovate and dusk-bot PRs that satisfy 3b.1–3b.7 are auto-merged. The bot has been pre-authorised by Renovate's auto-merge config on the repo; this skill is the executor.

### 3c — Flag for human review

Everything else. Specifically:

- CI red, pending, or missing the required checks.
- Merge conflicts.
- A review with `REQUEST_CHANGES` not yet dismissed.
- Breaking change in title or body.
- Diff touches more than 20 lines OR is not a pure version-pin / image-tag.
- Author is a human AND the PR has been open >7 days with no reviewer activity (operator should bump or close).
- Renovate-major PRs where the dependency has a known migration guide (e.g. renovate-operator 6.x) — link the guide in the flag message.

## Step 4 — Merge safe PRs

For each PR that passes 3b:

```bash
curl -s -X POST -H "Authorization: token $FORGEJO_PAT" \
  -H 'Content-Type: application/json' \
  -d '{"Do":"squash","merge_when_checks_succeed":true,"delete_branch_after_merge":true}' \
  "https://git.dcunha.io/api/v1/repos/exikle/${REPO}/pulls/${NUMBER}/merge"
```

Verify the response has `merged: true`. On a 405 (merge blocked) or 409 (conflict re-detected), downgrade that PR to 3c and continue.

**Hard cap:** do not batch-merge more than 10 PRs in one run. If more than 10 qualify, merge the 10 oldest and flag the rest for human attention.

## Step 5 — Notify

Compose a single chaski message summarising the run. Use the same chaski curl pattern as the cluster-health skill (`http://chaski.observability.svc.cluster.local:8080/hooks/{info|warning}`).

- Route `info` if everything merged cleanly with no flags.
- Route `warning` if anything was flagged or any merge failed.
- Route `critical` ONLY if `$FORGEJO_PAT` is missing or returned 401 — the token broke, operator needs to know.

Body format:

```text
<b>Merged:</b> N (list: exikle/repo#123 — title)
<b>Flagged (needs review):</b> M (list with the criteria that failed)
<b>Skipped (draft / no PRs):</b> K (count)
```

URL: `https://git.dcunha.io/exikle/-/pulls?state=open&sort=recentupdate`

## Hard rules

- **Never** force-push or push anything; you are read+merge only.
- **Never** merge into `main` on `exikle/containers` — it has a release-flow pipeline that should run on its own.
- If `$FORGEJO_PAT` is missing or returns 401, abort immediately and post a single `critical` chaski message — the operator needs to know the token broke.
- If the diff includes any of: secrets, RBAC changes, CRD additions, NodeSelector/Affinity changes, or anything in `kube-system`/`flux-system`/`external-secrets` namespaces — flag, do not auto-merge.
