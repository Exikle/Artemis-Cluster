---
name: forgejo-pr-review
description: "Daily review of every open PR in the Forgejo exikle org. Merges what is safe (CI green, no requested changes, no conflicts, not draft, not renovate/dusk-bot), flags the rest. Notifies via chaski."
version: 1.0.0
author: Artemis
license: MIT
platforms: [linux]
metadata:
    hermes:
        tags: [Forgejo, Pull-Requests, CI/CD, Automation, Merge]
        related_skills: []
---

# Forgejo Daily PR Review

You are running on a daily schedule (09:00) to clean up the Forgejo org at `https://git.dcunha.io`. Goal: merge PRs that are obviously safe to merge, and surface everything else as a clear list for human review.

## Auth

The `FORGEJO_PAT` env var holds a personal access token with `repo` and `write:repository` scopes (read PRs, write merge). Use it via `-H "Authorization: token $FORGEJO_PAT"`. Never echo the token. If it is unset, abort and notify via chaski (route `warning`) — do not retry.

## Step 1 — Enumerate repos

List every repo in the `exikle` org:

```bash
curl -s -H "Authorization: token $FORGEJO_PAT" \
  'https://git.dcunha.io/api/v1/orgs/exikle/repos?limit=50' \
  | python3 -c "import sys,json; [print(r['name']) for r in json.load(sys.stdin)]"
```

Pagination: if `Link` header contains `rel="next"`, follow it until exhausted. (Forgejo's API is identical to Gitea's.)

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

## Step 3 — Per-PR checks

Before merging any PR, **all** of these must be true:

1. **Not a draft.** Skip `draft: true`.
2. **CI green.** Check the most recent commit's status. Use `GET /repos/exikle/{repo}/commits/{sha}/statuses` — there must be no `failure` or `pending` state; either no statuses at all (no required CI for this repo) or all `success`. Renovate and dependency-bump PRs skip Tekton by convention; if no CI ran on the head SHA and the diff is purely version-pin changes, treat as green.
3. **No requested changes.** Check reviews: `GET /repos/exikle/{repo}/pulls/{index}/reviews` — there must be no review with `state: "REQUEST_CHANGES"` that hasn't been dismissed. `APPROVED` reviews from anyone are accepted.
4. **Mergeable.** `mergeable` field is `true`. (`mergeable_state == "clean"` or `"unstable"` is fine; `"dirty"` or `"blocked"` is not.)
5. **No merge conflicts.** Confirmed by the `mergeable` flag above.
6. **Author is not renovate or dusk-bot** unless explicitly approved by a human in the last 24h. (Renovate's PRs often stack up — only merge the most recent per dependency unless a human approved older ones.)

**Skip without flagging:**

- PRs marked `draft: true` (the author knows they're not ready).
- PRs from `renovate[bot]`, `dusk-bot`, `github-actions[bot]` where there's no human approval.

**Flag (do not merge) when any of:**

- CI is red or pending.
- A review has `REQUEST_CHANGES` not yet dismissed.
- Merge conflicts.
- Author is a human and the PR has been open >7 days with no reviewer activity (operator should bump or close).

## Step 4 — Merge safe PRs

For each PR that passes all checks:

```bash
curl -s -X POST -H "Authorization: token $FORGEJO_PAT" \
  -H 'Content-Type: application/json' \
  -d '{"Do":"squash","merge_when_checks_succeed":true,"delete_branch_after_merge":true}' \
  "https://git.dcunha.io/api/v1/repos/exikle/${REPO}/pulls/${NUMBER}/merge"
```

Verify the response has `merged: true`. On a 405 (merge blocked) or 409 (conflict re-detected), downgrade that PR to "flagged" and continue.

## Step 5 — Notify

Compose a single chaski message summarising the run. Format:

```bash
CHASKI=http://chaski.observability.svc.cluster.local:8080
ROUTE=info   # 'warning' if any merge failed or anything needs human attention

curl -s -X POST "$CHASKI/hooks/$ROUTE" \
  -H 'Content-Type: application/json' \
  -d @- <<JSON
{
  "title": "Daily PR review",
  "message": "$(cat <<'EOF'
<b>Merged:</b> N (list: exikle/repo#123 — title)
<b>Flagged (needs review):</b> M (list)
<b>Skipped (draft / bot / no review):</b> K (count)
EOF
)",
  "url": "https://git.dcunha.io/exikle/-/pulls?state=open&sort=recentupdate"
}
JSON
```

If `M > 0` (anything flagged), **also** send a per-PR `warning` message with the criteria that failed.

If `N + M + K == 0` (nothing to do), send a single `info` "no open PRs across the org" message.

## Hard rules

- **Never** merge a PR from `renovate[bot]` or `dusk-bot` unless a human has approved it in the last 24h.
- **Never** merge into `main` on `exikle/containers` — it has a release-flow pipeline that should run on its own.
- **Never** force-push or push anything; you are read+merge only.
- If `$FORGEJO_PAT` is missing or returns 401, abort immediately and post a single `critical` chaski message — the operator needs to know the token broke.
