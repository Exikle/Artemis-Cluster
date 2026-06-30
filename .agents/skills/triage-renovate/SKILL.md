# Skill: Triage Renovate

Triage open Renovate PRs in Artemis-Cluster via Forgejo and output a prioritized merge order.

## Fetch Open PRs

Use `mcp__artemis-ops__mcp-forgejo_list_pull_requests`:

- `owner: exikle`, `repo: Artemis-Cluster`
- Filter for PRs with `renovate` in the branch name or author

Or via CLI:

```bash
FORGEJO_TOKEN=$(op read 'op://kubernetes/forgejo/FORGEJO_ADMIN_TOKEN')
curl -s "https://git.dcunha.io/api/v1/repos/exikle/Artemis-Cluster/pulls?state=open&limit=50" \
  -H "Authorization: Bearer $FORGEJO_TOKEN" | jq '.[].title'
```

## Classify Each PR

| Type                                    | Risk      | Notes                                                           |
| --------------------------------------- | --------- | --------------------------------------------------------------- |
| Digest-only (`sha256` change, same tag) | 🟢 Low    | Safe to auto-merge                                              |
| Patch (`x.y.Z`)                         | 🟢 Low    | Safe if CI passes                                               |
| Minor (`x.Y.z`)                         | 🟡 Medium | Skim changelog for deprecations                                 |
| Major (`X.y.z`)                         | 🔴 High   | Read changelog, check breaking changes                          |
| Flux/kube-system/rook-ceph/cert-manager | 🔴 High   | Apply last; may need manual verification                        |
| CRD-bearing Helm chart                  | 🔴 High   | CRDs apply first (check for `CustomResourceDefinition` in diff) |

## Auto-Merge (when CI passes)

```bash
FORGEJO_TOKEN=$(op read 'op://kubernetes/forgejo/FORGEJO_ADMIN_TOKEN') && \
curl -s -X POST "https://git.dcunha.io/api/v1/repos/exikle/Artemis-Cluster/pulls/<PR_NUMBER>/merge" \
  -H "Authorization: Bearer $FORGEJO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"Do":"squash","merge_when_checks_succeed":true,"delete_branch_after_merge":true}'
```

Or use `mcp__artemis-ops__mcp-forgejo_merge_pull_request` — note it does NOT support `merge_when_checks_succeed`, so use the API directly for auto-merge.

## Merge Order Rules

1. Digests and patches first (lowest risk, unblock queue)
2. Minor bumps next (after changelog check)
3. Infrastructure last: `flux-system`, `kube-system`, `rook-ceph`, `cert-manager`, `network`
4. Major bumps: one at a time, manual confirmation

## Output Format

```
## Renovate Triage — 2026-06-18

| # | PR | Type | Risk | Action |
|---|-----|------|------|--------|
| 1 | #510 prometheus-blackbox 11.12→11.13 | patch | 🟢 | Auto-merge |
| 2 | #494 minecraft-server digest update | digest | 🟢 | Auto-merge |
| 3 | #515 actions/checkout v6→v7 | major | 🔴 | Check changelog |
| 4 | #520 rook-ceph 1.14→1.15 | minor | 🟡 | Review CRDs |

PRs #510 and #494 queued for auto-merge. PRs #515 and #520 need manual review.
```
