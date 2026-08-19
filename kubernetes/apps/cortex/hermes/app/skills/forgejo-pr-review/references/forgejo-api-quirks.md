# Forgejo API Quirks — observed during PR review runs

Field naming and endpoint behaviours that differ from what you might expect
from the GitHub API. These are stable Forgejo behaviours, not transient issues.

## Combined commit status: `state` vs `status`

`GET /repos/{owner}/{repo}/commits/{sha}/status` returns:

```json
{
  "state": "success",        // ← top-level field is "state"
  "statuses": [
    {
      "status": "success",   // ← per-check field is "status", NOT "state"
      "context": "Labeler (Tekton) / Labeler (pull_request)",
      ...
    },
    {
      "status": "success",
      "context": "Konflate",
      ...
    }
  ]
}
```

If you iterate `statuses[]` and read `s.get('state')` you get `None` for every
check — making it look like checks are missing even when CI passed. Always use
`s.get('status')` for individual checks and `data.get('state')` for the overall
verdict.

## `/pulls/{index}/files` — no `patch` field

The files endpoint returns objects with `filename`, `additions`, `deletions`,
`status`, etc., but **no `patch` field** — unlike GitHub's equivalent. To see
the actual diff content (needed to verify a change is a pure version-pin and
not a secret/RBAC/CRD edit), request the raw diff:

```bash
curl -s --max-time 30 -H "Authorization: token $FORGEJO_PAT" \
  -H "Accept: text/plain" \
  -o /tmp/diff-text-${REPO}-${NUMBER}.txt -w 'diff-text HTTP %{http_code}\n' \
  "https://git.dcunha.io/api/v1/repos/exikle/${REPO}/pulls/${NUMBER}.diff"
```

Then `read_file` the `.txt` to inspect the actual `+`/`-` lines.

## `mergeable_state` is frequently `null`

Forgejo returns `mergeable_state: null` (Python `None`) on repos that haven't
computed the mergeable state yet. This is not a problem — if `mergeable: true`
and CI status is `success`, treat as mergeable. The skill already documents
this in 3b.2; this confirms it is still the behaviour as of 2026-08.

## Review states: `REQUEST_REVIEW` ≠ `REQUEST_CHANGES`

`GET /pulls/{index}/reviews` can return reviews with `state: "REQUEST_REVIEW"`
(Exikle requesting a review from someone). This is **not** a disapproval — only
`REQUEST_CHANGES` blocks auto-merge. `REQUEST_REVIEW`, `APPROVED`, and
`COMMENTED` are all safe.

## Merge response: 201 = queued, not merged

A `201 Created` response from the merge endpoint with
`merge_when_checks_succeed: true` means Forgejo has **scheduled** the merge,
not completed it. Always verify with a follow-up `GET /pulls/{index}`:

- `merged: true` → landed, count in `stats.merged`
- `state: "open"`, `merged: false` → queued, count in `stats.flagged` with
  reason `queued pending CI`

This is already documented in Step 4 but confirmed again: both PRs merged in
the 2026-08-17 run returned 201 and were still `open` on verification.
