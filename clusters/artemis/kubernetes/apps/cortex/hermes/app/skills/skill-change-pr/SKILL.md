---
name: skill-change-pr
description: "How to get one of your skills changed. Skills are read-only (git is the source), so open a Forgejo PR as dusk-bot instead of editing. Use whenever a skill is wrong, stale, or missing a step."
---

# Change a skill with a PR

Skills under `/etc/hermes-skills/` are read-only mounts of `clusters/artemis/kubernetes/apps/cortex/hermes/app/skills/<name>/` in `exikle/home-infra`. Do not edit them or patch them with skill tools, because the write fails or is staged and never lands. Open a PR. Never merge it. The merge is denied and a human decides.

Use scanner-safe shapes only: `curl -o <file>` then `read_file`. Do not pipe into interpreters, do not use heredocs, and do not use `jq`. `write_file` refuses `/tmp`, so author files under `/opt/data/workspace/skill-pr/`. Auth is `Authorization: token $FORGEJO_PAT` (dusk-bot). `B=https://git.dcunha.io/api/v1/repos/exikle/home-infra`.

1. Read the current file and note its `sha`:

```bash
curl -s --max-time 30 -H "Authorization: token $FORGEJO_PAT" -o /tmp/cur.json -w '%{http_code}\n' "$B/contents/kubernetes/apps/cortex/hermes/app/skills/<name>/SKILL.md?ref=main"
grep -o '"sha":"[^"]*"' /tmp/cur.json
```

2. `write_file` the full new text to `/opt/data/workspace/skill-pr/new.md`. Then `base64 -w0 /opt/data/workspace/skill-pr/new.md > /tmp/new.b64` and `read_file /tmp/new.b64`. Keep one trailing newline.

3. `write_file` `/opt/data/workspace/skill-pr/put.json`. `branch` is the base, `new_branch` is created from it (add `-2`, `-3` if it exists):

```json
{
    "message": "feat(hermes): <what>",
    "branch": "main",
    "new_branch": "feat/hermes-<name>-<YYYYMMDD>",
    "sha": "<sha from step 1>",
    "content": "<base64 string>"
}
```

```bash
curl -s --max-time 60 -X PUT -H "Authorization: token $FORGEJO_PAT" -H 'Content-Type: application/json' --data @/opt/data/workspace/skill-pr/put.json -o /tmp/put.json -w '%{http_code}\n' "$B/contents/kubernetes/apps/cortex/hermes/app/skills/<name>/SKILL.md"
```

The code 200 means committed. For a second file in the same PR, repeat steps 1-3 with `"branch": "<the new branch>"` and no `new_branch`. For a brand-new file, use `-X POST` and no `sha`. A new file also needs an entry in `kustomization.yaml` and `helmrelease.yaml` of that app, so change those in the same PR.

4. `write_file` `/opt/data/workspace/skill-pr/pr.json`, then open the PR:

```json
{
    "head": "feat/hermes-<name>-<YYYYMMDD>",
    "base": "main",
    "title": "feat(hermes): <what>",
    "body": "What: <one line>.\nWhy: <the failure or gap>.\nEvidence: <run id, log line, or tool output that showed it>."
}
```

```bash
curl -s --max-time 30 -X POST -H "Authorization: token $FORGEJO_PAT" -H 'Content-Type: application/json' --data @/opt/data/workspace/skill-pr/pr.json -o /tmp/pr.json -w '%{http_code}\n' "$B/pulls"
```

The code 201 means opened. Report the `html_url` from `/tmp/pr.json` to the user and stop. If the PUT returns 409, the file changed. Redo from step 1 once.
