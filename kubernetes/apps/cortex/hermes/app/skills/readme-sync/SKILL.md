---
name: readme-sync
description: "Weekly README drift check across the Artemis and Frostlink repos. Reconciles the `kubernetes/apps/` directory tree and namespace comments in each repo's README.md against the live manifest state on Forgejo, regenerates any drifted sections, and commits the fix back via the Contents API. Notifies via chaski. Designed for the hermes cron scheduler."
version: 1.1.0
author: Artemis
license: MIT
platforms: [linux]
metadata:
    hermes:
        tags: [GitOps, Documentation, Forgejo, Self-Healing, Operations]
        related_skills: [cluster-health, forgejo-pr-review]
---

# Weekly README Sync

You are running on a weekly schedule (Sunday 08:00 ET, cron `0 8 * * 0`). Goal: keep the
`README.md` of the Artemis and Frostlink repos honest by reconciling the sections
that describe the apps tree. Fix what drifted, commit the fix, notify via chaski.

## Scanner-safe command shapes — read before running anything

This skill runs unattended from cron. The security scanner flags **pipes into an
interpreter** (`curl … | python3`) and **inline interpreter scripts** (`python3 -c '…'`)
as HIGH and marks the command `pending_approval`, which stalls the run — the job neither
completes nor notifies. Every API call below therefore writes its response to a file with
`curl -o` and prints only the HTTP code; you then `read_file` and parse it yourself.

Note the asymmetry that governs every path in this skill: **`curl -o /tmp/…` is allowed,
but the `write_file` tool refuses `/tmp`** as a protected system path. So responses you
_download_ live in `/tmp/`, and every file you _author_ — the edited README, the payload —
lives under `/opt/data/workspace/.readme-sync/`. Mixing these up is the difference between
a working run and one that dies mid-edit.

## Tools you have

- **Forgejo REST API** (`https://git.dcunha.io/api/v1`). Auth via `$FORGEJO_PAT`
  (a personal access token with `repo` scope). Read endpoints to enumerate app
  directories; Contents API to GET and PUT README.md.
- **curl / terminal** for the above.
- **k8s-mcp** (`/ops/mcp`) — full cluster query API. Use for the optional step
  that injects live node/hardware facts into the Hardware table.
- **chaski** (`http://chaski.observability.svc.cluster.local:8080`) — POST the
  structured payload defined in Step 9 to `/hooks/{info|warning|critical}`.
  chaski renders the message; you never format it yourself.

## Repos in scope

Two repos, both running on Forgejo. Owner is `exikle`. The README structure
differs between them so the per-repo checks below are intentionally separate.

| Repo      | Forgejo path             | README backbones                                                               |
| --------- | ------------------------ | ------------------------------------------------------------------------------ |
| Artemis   | `exikle/Artemis-Cluster` | `Kubernetes → Directories → 📁 kubernetes → 📁 apps → …` plus `Hardware` table |
| Frostlink | `exikle/frostlink`       | smaller — `## Cluster` fact table + `## Structure` directory list              |

> Both repos sit behind a hub-spoke topology: Artemis is the primary homelab,
> Frostlink is the Oracle Cloud Always Free secondary. The README tables should
> never claim apps that aren't reconciled by Flux, and must never miss apps that
> are.

## Step 1 — Abort preflight

Before doing anything, check that `$FORGEJO_PAT` is set:

```bash
[ -n "$FORGEJO_PAT" ] && echo "PAT present" || echo "PAT MISSING"
```

If it is missing (or any call below returns 401), **send the `critical` notification from
Step 9 first, then stop.** Do not `exit 1` on the spot: exiting the shell ends the run
before the notification is sent, so a broken token would fail completely silently — which
is the one failure mode this preflight exists to prevent. Set `status: "failed"`,
`*_push: "failed"`, counts 0, and say the token broke in `summary`.

## Step 2 — Fetch each repo's current README

Fetch **once** and reuse — the response carries both the `sha` and the base64 `content`,
so a second identical call is wasted work and risks reading a different revision than the
one you are about to base an edit on:

```bash
mkdir -p /opt/data/workspace/.readme-sync
REPO=Artemis-Cluster   # or 'frostlink' for the second pass
curl -s --max-time 30 -H "Authorization: token $FORGEJO_PAT" \
  -o /tmp/${REPO}-readme.json -w "readme ${REPO} HTTP %{http_code}\n" \
  "https://git.dcunha.io/api/v1/repos/exikle/${REPO}/contents/README.md?ref=main"
```

`read_file /tmp/${REPO}-readme.json`, take `.sha` and `.content`, and `write_file` the
decoded markdown to `/opt/data/workspace/.readme-sync/${REPO}-pre.md`.

Hold the `sha` — every PUT must include it or Forgejo rejects with 409. A 404 here means
the repo has no `README.md`: skip that repo, count it as flagged, and move on.

## Step 3 — Enumerate live app directories

For each repo, list the apps tree by walking the Contents API. The pattern
recurses one level into each `apps/<ns>/` and lists the app directory names.

```bash
# namespaces
curl -s --max-time 30 -H "Authorization: token $FORGEJO_PAT" \
  -o /tmp/${REPO}-ns.json -w 'ns HTTP %{http_code}\n' \
  "https://git.dcunha.io/api/v1/repos/exikle/${REPO}/contents/kubernetes/apps?ref=main"

# apps within one namespace (repeat per namespace)
curl -s --max-time 30 -H "Authorization: token $FORGEJO_PAT" \
  -o /tmp/${REPO}-ns-${NS}.json -w "apps ${NS} HTTP %{http_code}\n" \
  "https://git.dcunha.io/api/v1/repos/exikle/${REPO}/contents/kubernetes/apps/${NS}?ref=main"
```

`read_file` each and keep the entries whose `type` is `dir`. **A non-200 on any of these
listings invalidates the whole diff for that repo** — an empty or partial `live_tree`
would look exactly like "every app was deleted" and could drive a catastrophic README
rewrite. On any listing error, abort this repo, leave its README untouched, and flag it.

Assemble the results into a `live_tree` of the form `{ '<ns>': [<app>, ...], ... }`.

For Artemis, the namespaces you should expect are documented in
`.agents/instructions/cluster-conventions.md` and `AGENTS.md`. For Frostlink,
the structure is shallower — typically 4–8 namespaces; just use what is there.

**Special case: `kube-system`** is populated by Cilium/CoreDNS/etc. and the
README descriptions for those are hand-written and stable. Only flag a drift in
`kube-system` if a subdirectory is _added_ or _removed_, not if an internal
manifest changes.

## Step 4 — Extract the README's claimed tree

Parse the existing README and pull out the same information. The Artemis README
encodes this in a fenced `sh` block under `### Directories`. Locate it by heading, never
by line number — the block moves every time the README changes.
Each line looks like:

```text
│   ├── 📁 cortex                 # AI stack — Open WebUI, SearXNG, ...
```

A small awk/python script should parse each line, capture the `📁 <name>` and the
trailing `# comment`. Output a `readme_tree` of the same `{ '<ns>': [(app,
comment), ...] }` shape.

If the README uses a different layout that you cannot robustly parse, **abort
the drift check for that repo and flag for human review** rather than guess.
Guessing a wrong edit is worse than no edit.

## Step 5 — Diff

Compare `live_tree` vs `readme_tree`:

| Drift                                        | What to do                                                                                                                       |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| App in live, missing from README             | add the line to the README's `### Directories` block                                                                             |
| App in README, absent from live              | remove the line                                                                                                                  |
| Namespace-level comment drifted              | update the `# AI stack — …` text to match the latest namespace.yaml                                                              |
| Namespace added entirely (live but no block) | add a new namespace block                                                                                                        |
| Namespace removed (block but no live dir)    | delete the block                                                                                                                 |
| App's trailing comment outdated / stale      | regenerate from the namespace's latest `AGENTS.md` annotation if present, otherwise drop the comment and leave just the app name |

When in doubt, prefer **fewer characters of human prose** in the README.
A correct, comment-less `│   ├── 📁 foo` is better than a wrong, comment-laden
one. The Hand-Edited Drift section explains why.

## Step 6 — Apply the patch

`write_file` the patched markdown to
`/opt/data/workspace/.readme-sync/${REPO}-post.md`, leaving the `-pre.md` untouched as
the rollback copy. Both live under `/opt/data/workspace/` because `write_file` cannot
write to `/tmp`. Compute the diff to confirm:

```bash
diff -u /opt/data/workspace/.readme-sync/${REPO}-pre.md \
        /opt/data/workspace/.readme-sync/${REPO}-post.md | head -200
```

If the diff is empty, the README was already in sync — skip the PUT for this
repo and continue to the next one.

**Sanity-gate the diff before pushing.** If it removes more than 25% of the file's lines,
or touches any line outside the sections this skill models, do not PUT: keep `-pre.md`,
flag the repo, and let a human look. A regeneration bug and a genuine mass deletion look
identical in a diff, and only one of them should ever reach `main` unattended.

## Step 7 — Push the fix

Encode the new content base64 and PUT back via the Contents API. **Always** pass
the original `sha` from Step 2; a stale sha returns 409 conflict and you must
re-fetch and try once before giving up.

Base64-encode with the `base64` binary (no interpreter), assemble the request body with
`write_file`, and POST it with `--data @file`:

```bash
D=/opt/data/workspace/.readme-sync
base64 -w0 "$D/${REPO}-post.md" > "/tmp/${REPO}-post.b64"
```

`read_file /tmp/${REPO}-post.b64`, then `write_file` `$D/${REPO}-put.json`:

```json
{
    "message": "docs(README): sync apps tree via readme-sync",
    "branch": "main",
    "sha": "<sha from Step 2>",
    "content": "<the base64 string>"
}
```

```bash
curl -s --max-time 60 -X PUT -H "Authorization: token $FORGEJO_PAT" \
  -H 'Content-Type: application/json' \
  --data @"$D/${REPO}-put.json" \
  -o /tmp/${REPO}-put-resp.json -w 'PUT HTTP %{http_code}\n' \
  "https://git.dcunha.io/api/v1/repos/exikle/${REPO}/contents/README.md"
# 200/201 = landed; read_file the response and record .commit.sha
```

`base64 -w0` matters: without it GNU base64 wraps at 76 columns and the embedded newlines
corrupt the JSON string.

If the PUT returns 409 (sha conflict): re-read the README from Step 2, re-apply
Step 5 against the freshly-read content (the diff is likely a no-op now — some
other committer raced us), and only PUT if there is still a real diff to land.
Cap at **one retry**; if it still conflicts, drop to Step 9 with a `warning`
chaski message.

## Step 8 — Optional: hardware/live-facts sweep

The Artemis README has a `## 🔧 Hardware` table. Its rows are mostly stable;
the ones that drift more often are:

- `Talos Linux` version column (when upgraded via tuppr)
- `Kubernetes` version column (same)
- Hardware rows for nodes that come and go (rare; the cluster has been at
  `talos-cp-01/02/03 + talos-w-01/02 + talos-gpu-01 + ymir` since 2026)

If you can read these facts (k8s-mcp has them; or skip if not reachable), update
the corresponding cells. **Do not** add rows the README doesn't already have —
adding a row about a "new node" implies the operator agreed, and the operator
should be the one to call that.

For Frostlink, the `## Cluster` fact table is similarly stable. Only update
fields whose value you can verify with high confidence; flag everything else
for the operator.

## Step 9 — Notify

**chaski owns the formatting, you supply data only.** Do not write HTML, markdown,
bullets, or a pre-formatted body — the `hermes-*` templates in chaski's config build
the notification. Any markup you put in a value is HTML-escaped and shown literally.

Send exactly one notification per run. **Do not build the JSON inline in the shell** — a
heredoc trips the scanner and stalls the run. `write_file` it, then POST with `--data @file`:

1. `write_file` to `/opt/data/workspace/.readme-sync/notify.json`:

```json
{
    "skill": "readme-sync",
    "status": "ok",
    "summary": "Both READMEs reconciled and pushed.",
    "stats": {
        "artemis_added": 2,
        "artemis_removed": 0,
        "artemis_push": "ok",
        "frostlink_added": 0,
        "frostlink_removed": 1,
        "frostlink_push": "skipped",
        "flagged": 0
    },
    "items": [],
    "url": "https://git.dcunha.io/exikle/Artemis-Cluster/commits/main"
}
```

2. POST it (`ROUTE` per the routing table below):

```bash
curl -s --max-time 15 -X POST -H 'Content-Type: application/json' \
  --data @/opt/data/workspace/.readme-sync/notify.json \
  "http://chaski.observability.svc.cluster.local:8080/hooks/$ROUTE" \
  -o /tmp/chaski_resp.txt -w 'HTTP %{http_code}\n'
```

**Order `items` by descending importance** — only the first 4 render in Pushover, the rest
collapse to "…N more". Failed pushes first, then repos that could not be parsed or listed,
then advisory notes. Never let a routine note push a failure out of view.

Field rules — every key required, exact names, exact types:

| Key       | Type   | Rule                                                                                                                                                                                                                                                                      |
| --------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `skill`   | string | always the literal `readme-sync` — never a variation                                                                                                                                                                                                                      |
| `status`  | string | exactly one of `ok` \| `attention` \| `failed`; anything else renders `MALFORMED`                                                                                                                                                                                         |
| `summary` | string | one plain-text sentence, no markup, truncated at 140 chars                                                                                                                                                                                                                |
| `stats`   | object | keys exactly `artemis_added`, `artemis_removed`, `artemis_push`, `frostlink_added`, `frostlink_removed`, `frostlink_push`, `flagged`; the `*_added`/`*_removed`/`flagged` values are integers (0, not null), the `*_push` values are one of `ok` \| `skipped` \| `failed` |
| `items`   | array  | plain strings, one per flagged item; first 4 shown, the rest collapse to "…N more"                                                                                                                                                                                        |
| `url`     | string | must start with `https://` or it is dropped                                                                                                                                                                                                                               |

Status meaning: `ok` = all updates landed cleanly or nothing needed updating.
`attention` = a push failed, a README couldn't be parsed, or the hardware sweep turned
up something unverifiable. `failed` = the sync itself could not run.

Routing: `info` when `status` is `ok`, `warning` when `attention`, `critical` only when
`failed` because `$FORGEJO_PAT` is missing or returns 401 — same threshold as the other
skills.

## Hard rules

- **Never** push to `main` on `exikle/containers`. The README there is part of
  the container-image release flow — humans edit it. Skip it.
- **Never** push if the diff touches a section the skill did not explicitly
  model (the `## 🤝 Acknowledgments` list, the inline logo, badge URLs, the
  intro paragraph, the `## 📝 License` block). If your edit accidentally
  reformats those, abort the PUT, restore from the pre-edit file, and flag.
- **Never** delete a README line you cannot prove exists in `kubernetes/apps/`.
  When the Forgejo API says the file doesn't exist any more, double-check with
  the `git ls-tree` semantics of the Contents API before deciding the
  namespace really is gone.
- **Never** commit secrets. The README should never contain tokens, FQDNs gated
  behind Cloudflare Access, or private IPv4s outside the documented VLANs. If
  your regeneration would introduce one, do not commit — flag.
- **Never** commit during a Flux run. If `kubectl get gitrepositories.source.toolkit.fluxcd.io -A` shows
  progress (`status.observedGeneration != status.revisionGeneration`), wait it
  out (≤2 min) or skip the PUT this week and flag.
- **Always** preserve a single trailing newline at EOF (`oxfmt` may reject
  otherwise — see `.oxfmtrc.json`).
- **Always** leave the badge block (`<div align="center">` …) **byte-identical**.
  Kromgo URLs and badge alt-text are operator-managed. If your pipeline would
  perturb them, scope the patch to skip that range.

## Hand-edited drift

The first run of this skill will surface drift that has accumulated since the
README was last touched by a human. Some of it is intentional:

- The intro poem (`_... where YAML is law, …_`) is hand-edited; never regenerate.
- The `## 🤝 Acknowledgments` list is curated; never regenerate.
- The badge URLs under the `<div align="center">` blocks are pinned by the
  operator; never regenerate.
- The `## 📝 License` block is fixed; never regenerate.

The skill is intentionally scoped to the `## ⛵ Kubernetes` block and (with the
operator's later blessing) the `## 🔧 Hardware` table. Sections outside those
are out of scope; if you find drift outside them, **flag**, don't auto-fix.

## Step 10 — Self-review

Same posture as `cluster-health`. After the run:

- If the diff you committed reintroduces a problem (e.g. a wrong namespace
  comment that the _next_ run will then propagate every week), write a proposal
  to `/opt/data/workspace/.skill-proposals/$(date -I)-readme-sync.md` describing
  the fix.
- Auto-commit proposals to this skill are gated by the same 15-line net-diff
  rule the other skills follow. Use the same Forgejo Contents API pattern as
  `cluster-health` Step 5.3 to push.
- New check / new behaviour proposals stay flagged; do not auto-merge.
