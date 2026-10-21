---
name: forgejo-gitea-api
description: "Read files, trees, commits or PRs on the self-hosted Forgejo at git.dcunha.io with curl, or open a PR. Use for 'read the repo', 'file tree', 'fetch file', 'open a PR', or when web_extract refuses the host."
---

# Forgejo REST API (git.dcunha.io)

Base: `https://git.dcunha.io/api/v1`. Repos `exikle/Artemis-Cluster` and `exikle/frostlink` read without auth.
Writes: header `Authorization: token $FORGEJO_PAT` (this is dusk-bot).

## Command shape (scanner-safe)

- `curl -s -o /tmp/x.json -w '%{http_code}\n' <url>` then `read_file` or `grep` the file.
- Never pipe curl into `python3`/`jq` (`jq` is not installed). No `python3 -c`. `execute_code` is blocked in cron.
- `write_file` refuses `/tmp`. Files you author go under `/opt/data/workspace`.

## Endpoints

| Need                  | Path                                                          |
| --------------------- | ------------------------------------------------------------- |
| Repo + default branch | `GET /repos/{o}/{r}`                                          |
| File tree             | `GET /repos/{o}/{r}/git/trees/{branch}?recursive=true&page=N` |
| Raw file              | `GET /repos/{o}/{r}/raw/{path}`                               |
| Directory             | `GET /repos/{o}/{r}/contents/{path}`                          |

## Pitfalls

- Tree answers are paged. If `"truncated":true`, request `page=2, 3...` until you have `total_count` entries.
- `web_extract` refuses this host (private-address filter). Do not retry it. Use curl.
- You cannot merge PRs or push `main` (denied). Open a PR from a branch instead. The branch, contents PUT and PR steps are in skill `skill-change-pr`.
- URL-encode special characters in paths.
