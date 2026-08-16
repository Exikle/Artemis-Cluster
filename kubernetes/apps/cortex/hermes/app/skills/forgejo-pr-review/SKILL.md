---
name: forgejo-pr-review
description: "Daily review of every open PR in the Forgejo exikle org. Auto-merges dependency bumps that pass the 2 forgejo CI checks (labeler + konflate) and have no breaking-change markers; flags the rest. Notifies via chaski."
version: 2.3.0
author: Artemis
license: MIT
platforms: [linux]
metadata:
    hermes:
        tags: [Forgejo, Pull-Requests, CI/CD, Automation, Merge]
        related_skills: [cluster-health, readme-sync]
---

# Forgejo Daily PR Review

You are running on a daily schedule (09:00) to clean up the Forgejo org at `https://git.dcunha.io`. Goal: auto-merge dependency bumps that are obviously safe, and surface everything else as a clear list for human review.

## Auth

The `FORGEJO_PAT` env var holds **dusk-bot's** token (1Password item `dusk-bot`, field `DUSK_BOT_PAT` — the same identity Renovate authenticates as), with `repo` and `write:repository` scopes. It is deliberately _not_ Exikle's personal token: every merge this skill performs is attributed to the bot, keeping automation distinct from the human identity whose commits are GPG-signed. dusk-bot holds admin+push at the _repo_ level, but `main` on both repos carries a push whitelist containing only `Exikle` — repo permissions do not override branch protection, so dusk-bot can merge PRs but can never commit to `main` directly. Use it via `-H "Authorization: token $FORGEJO_PAT"`. Never echo the token. If it is unset or returns 401, abort and notify via chaski route `critical` — do not retry. (`critical` is the threshold for a broken token in all three skills; nothing else in this skill may use it.)

## Scanner-safe command shapes — read before running anything

This skill runs unattended from cron. The security scanner flags **pipes into an
interpreter** (`curl … | python3`) and **inline interpreter scripts** (`python3 -c '…'`)
as HIGH and marks the command `pending_approval`, which stalls the run — the job neither
completes nor notifies. Every API call below therefore follows one shape:

1. `curl` writes the response to a file under `/tmp/` and prints only the HTTP code.
2. You `read_file` that file and parse the JSON yourself.

Two constraints that bite in opposite directions: `curl -o /tmp/…` is fine, but the
`write_file` tool **refuses `/tmp`** as a protected path — anything you author goes to
`/opt/data/workspace/.pr-review/` instead. Use pure-bash arithmetic rather than python
for counting; never build JSON with a heredoc.

## Step 1 — Enumerate repos

`exikle` is a **user account**, not an org. List every repo owned by the user:

```bash
mkdir -p /opt/data/workspace/.pr-review
curl -s --max-time 30 -H "Authorization: token $FORGEJO_PAT" \
  -o /tmp/repos.json -w 'repos HTTP %{http_code}\n' \
  'https://git.dcunha.io/api/v1/users/exikle/repos?limit=50&page=1'
# expect 200, then read_file /tmp/repos.json and take each .name
```

Pagination: the response carries at most `limit` entries. If you get exactly 50 back,
fetch `&page=2`, `&page=3`, … into `/tmp/repos-2.json` etc. until a page returns fewer
than 50. A silently truncated repo list means PRs are never reviewed at all, so do not
skip this.

Skip these regardless of state:

- `exikle/containers` and any repo that is purely a CI/CD template farm (no PRs ever land there from humans).
- `exikle/homepage` and other personal-website repos — operator reviews those manually.

## Step 2 — List open PRs per repo

For each repo, fetch open PRs:

```bash
curl -s --max-time 30 -H "Authorization: token $FORGEJO_PAT" \
  -o /tmp/pulls-${REPO}.json -w "pulls ${REPO} HTTP %{http_code}\n" \
  "https://git.dcunha.io/api/v1/repos/exikle/${REPO}/pulls?state=open&limit=50&page=1"
# 200 = read_file and parse; 404 = PRs disabled on this repo (3a, skip);
# 5xx or 000 = transient, retry ONCE after 10s, then count the repo as skipped
```

Page the same way as Step 1 when a repo returns exactly 50 open PRs.

For each PR, capture: `number`, `title`, `user.username`, `head.ref`, `base.ref`,
`mergeable`, `mergeable_state`, `draft`, `created_at`.

**Transient failures are not "no PRs".** A repo whose listing errored must be counted in
`skipped` and named in `items` — never treated as clean. Silently reporting `merged: 0,
flagged: 0` because the API was down is the one outcome that would make this job lie.

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
- **PRs opened by the sibling hermes skills** — `docs(README): sync apps tree via readme-sync` from `readme-sync`, and `fix(skill/…)` from `cluster-health`'s self-improvement step. These are dusk-bot PRs and will look mergeable, but their title types are deliberately outside 3b.6 so they land here. An agent must not merge content another agent generated — README prose and a skill editing its own instructions both need a human read. Flag them with the reason `agent-authored, needs human review`.

## Step 4 — Merge safe PRs

**Only ever merge a PR whose `base.ref` is `main`.** A PR targeting a feature or release
branch is somebody's stacked work; merging it is not this skill's business. Anything with
another base goes to 3c.

For each PR that passes 3b:

```bash
curl -s --max-time 60 -X POST -H "Authorization: token $FORGEJO_PAT" \
  -H 'Content-Type: application/json' \
  -d '{"Do":"squash","merge_when_checks_succeed":true,"delete_branch_after_merge":true}' \
  -o /tmp/merge-${REPO}-${NUMBER}.json -w 'merge HTTP %{http_code}\n' \
  "https://git.dcunha.io/api/v1/repos/exikle/${REPO}/pulls/${NUMBER}/merge"
```

**Do not treat a 2xx as merged.** `merge_when_checks_succeed: true` lets Forgejo _queue_
the merge for when CI goes green, so a success response can mean "scheduled", not "landed".
Counting a queued PR as merged would report work that has not happened. Confirm by
re-reading the PR itself:

```bash
curl -s --max-time 30 -H "Authorization: token $FORGEJO_PAT" \
  -o /tmp/verify-${REPO}-${NUMBER}.json -w 'verify HTTP %{http_code}\n' \
  "https://git.dcunha.io/api/v1/repos/exikle/${REPO}/pulls/${NUMBER}"
```

- `merged: true` → count in `stats.merged`.
- `state: "open"` and `merged: false` → it was **queued, not merged**. Count it in
  `stats.flagged` with the reason `queued pending CI`, so the notification says what is
  actually true. It will merge itself or show up again tomorrow.
- 405 (merge blocked) / 409 (conflict re-detected) → downgrade to 3c and continue.

**Hard cap:** do not batch-merge more than 10 PRs in one run. If more than 10 qualify, merge the 10 oldest (by `created_at`) and flag the rest for human attention.

## Step 5 — Notify

**chaski owns the formatting, you supply data only.** Do not write HTML, markdown,
bullets, or a pre-formatted body — the `hermes-*` templates in chaski's config build
the notification. Any markup you put in a value is HTML-escaped and shown literally.

Send exactly one notification per run. **Do not build the JSON inline in the shell** — a
heredoc or `-d '{...}'` is escaping-heavy and trips the scanner, stalling the run.
`write_file` the payload, then POST it with `--data @file`:

1. `write_file` to `/opt/data/workspace/.pr-review/notify.json` (not `/tmp` — the file
   tool refuses it):

```json
{
    "skill": "forgejo-pr-review",
    "status": "ok",
    "summary": "4 dependency bumps merged, nothing flagged.",
    "stats": { "merged": 4, "flagged": 0, "skipped": 1 },
    "items": ["exikle/Artemis-Cluster#1580 — chore(deps): update cilium to 1.19.2"],
    "url": "https://git.dcunha.io/exikle/-/pulls?state=open&sort=recentupdate"
}
```

2. POST it (`ROUTE` per the routing table below):

```bash
curl -s --max-time 15 -X POST -H 'Content-Type: application/json' \
  --data @/opt/data/workspace/.pr-review/notify.json \
  "http://chaski.observability.svc.cluster.local:8080/hooks/$ROUTE" \
  -o /tmp/chaski_resp.txt -w 'HTTP %{http_code}\n'
```

A 200 with an empty body means chaski accepted and relayed it.

**Order `items` by descending importance** — only the first 4 render in Pushover and the
rest collapse to "…N more", so the ordering decides what the operator actually sees:
failed merges first, then flagged PRs, then repos skipped due to an API error, and merged
PRs last. A successful merge is the least interesting thing in the list; it is already
counted in `stats.merged`.

Field rules — every key required, exact names, exact types:

| Key       | Type   | Rule                                                                                                                                                   |
| --------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `skill`   | string | always the literal `forgejo-pr-review` — never a variation                                                                                             |
| `status`  | string | exactly one of `ok` \| `attention` \| `failed`; anything else renders `MALFORMED`                                                                      |
| `summary` | string | one plain-text sentence, no markup, truncated at 140 chars                                                                                             |
| `stats`   | object | integers only, keys exactly `merged`, `flagged`, `skipped` — 0, not null                                                                               |
| `items`   | array  | plain strings, one per PR (`exikle/repo#123 — title`, plus the criterion that failed for a flagged one); first 4 shown, the rest collapse to "…N more" |
| `url`     | string | must start with `https://` or it is dropped                                                                                                            |

Status meaning: `ok` = everything merged cleanly, nothing flagged. `attention` = something
was flagged or a merge failed. `failed` = the review itself could not run.

Routing: `info` when `status` is `ok`, `warning` when `attention`, `critical` only when
`failed` because `$FORGEJO_PAT` is missing or returned 401 — the token broke.

## Hard rules

- **Never** force-push or push anything; you are read+merge only.
- **Never** merge into `main` on `exikle/containers` — it has a release-flow pipeline that should run on its own.
- If `$FORGEJO_PAT` is missing or returns 401, abort immediately and post a single `critical` chaski message — the operator needs to know the token broke.
- If the diff includes any of: secrets, RBAC changes, CRD additions, NodeSelector/Affinity changes, or anything in `kube-system`/`flux-system`/`external-secrets` namespaces — flag, do not auto-merge.
