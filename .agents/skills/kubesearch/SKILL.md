---
name: kubesearch
description: Find real-world HelmRelease examples for an app by searching kubesearch.dev and other home-ops repos, then adapt the best match to this cluster's conventions. Use for "find examples for X", "how do others deploy X", "search kubesearch for X", or when deploying an unfamiliar app with no obvious reference. Scoped to the Artemis cluster.
compatibility: Requires outbound network access. It curls the static JSON of kubesearch.dev directly, with no MCP server and no API key. Read-only; it produces a manifest to adapt, it does not apply anything.
---

# Skill: Kubesearch — Find Home-Ops Examples

Search [kubesearch.dev](https://kubesearch.dev) for real HelmRelease examples from other home-ops clusters and adapt the best one to home-infra conventions.

kubesearch.dev indexes repos tagged `k8s-at-home` / `kubesearch` on GitHub and GitLab. Its search field is client-side JavaScript that loads static JSON files. This skill replicates that directly.

## Step 1: Identify the Query

Confirm the app name to search for (for example `sonarr`, `paperless-ngx`, `immich`). If you are in the middle of a task (for example, deploying an app), the query is the name of the app or chart that you deploy.

## Step 2: Search kubesearch.dev

Download all data chunks in parallel and filter by app name (substring match):

```bash
APP="<app-name>"
# The index grows; discover the last chunk instead of hardcoding it (was 84, now 100).
LAST=$(n=0; while curl -sfo /dev/null "https://kubesearch.dev/hr/data-$n.json"; do n=$((n+1)); done; echo $((n-1)))
seq 0 "$LAST" | xargs -P8 -I{} sh -c "
  curl -sL 'https://kubesearch.dev/hr/data-{}.json' | \
  python3 -c \"
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for v in data.values():
    if '${APP}' in v.get('name','').lower():
        best = sorted(v['repos'], key=lambda r: -r.get('stars',0))
        for r in best[:3]:
            print(r.get('stars',0), '|', v['name'], '|', r['repo'], '|', r['url'])
\" 2>/dev/null
" | sort -t'|' -k1 -rn | head -15
```

Coverage limit: read this before you trust a 0 result. The `/hr/` dataset only reliably
covers charts that come through a `HelmRepository`. It indexes HelmReleases that use `chartRef: OCIRepository` at
best partially. As of 2026-09-04, `miroir` returns **zero** hits here although about 31 repos
run it on GitHub. For an
infrastructure or storage chart, skip this step and go straight to GitHub code search.

If there are 0 results, the app is not indexed (it is less common or not tagged `k8s-at-home`). Fall back to GitHub through MCP:

Use the `github_search_code` tool of the ops tier with the query: `<app> filename:helmrelease.yaml path:kubernetes/apps`

Prioritize results in this order:

1. Highest star count (kubesearch sorts this naturally)
2. Well-known repos: `onedr0p/home-ops`, `gavinmcfall/home-ops`, `bjw-s/home-ops`, `drag0n141/home-ops`
3. `path` contains `clusters/artemis/kubernetes/apps` (home-ops layout)

## Step 3: Fetch the Top Result

Extract owner/repo and path from the chosen URL, then fetch through MCP:

Use the `github_get_file_contents` tool of the ops tier with `owner`, `repo`, and `path` from the result URL.

Fetch one or two results if the first looks incomplete (a stub, a `.yaml.j2` template, or a file that references other files).

## Step 4: Present and Adapt

Show the fetched YAML and note the source URL. Identify the key patterns:

- Image: repository + tag or digest
- Environment variables: app-specific env vars to carry forward
- Ports: HTTP port number
- Persistence: mount paths and PVC usage
- Secrets: which env vars come from secrets
- Security context: `runAsUser`, `readOnlyRootFilesystem`, and so on
- Database/cache dependencies: note any `dependsOn: dragonfly-cluster`, `mariadb`, or a per-app Postgres. You remap all of them onto our shared `database` namespace (see below)

Adapt to home-infra conventions:

| Theirs                                  | Artemis equivalent                                                                                                                                                                                                          |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `HelmRepository` + `chart:`             | Standalone `OCIRepository` → `oci://ghcr.io/bjw-s-labs/helm/app-template` at the current fleet tag (`grep -h 'tag:' clusters/artemis/kubernetes/apps/*/*/app/ocirepository.yaml \| sort \| uniq -c \| sort -rn \| head -1`) |
| Any `TZ:` env var                       | Remove it. k8tz handles timezone cluster-wide                                                                                                                                                                               |
| `secretRef` / `envFrom`                 | `ExternalSecret` via `onepassword-connect` ClusterSecretStore                                                                                                                                                               |
| `Ingress`                               | `HTTPRoute` inline in helmrelease values via `internal-gateway` (LAN) or `edge-gateway` (public)                                                                                                                            |
| `dependsOn: mariadb` / per-app Postgres | Shared CNPG cluster via `postgres-rw`. Add the `postgres` component + `PG_APP`                                                                                                                                              |
| `dependsOn: dragonfly-cluster` / Redis  | Shared Dragonfly at `dragonfly.database.svc.cluster.local:6379`                                                                                                                                                             |
| Any namespace                           | Match the target namespace of the user for this cluster                                                                                                                                                                     |

If the source already uses `app-template`, carry its `controllers`/`containers`/`persistence` structure directly. Update only the image and the secrets pattern.

## Common Issues / Gotchas

- `.yaml.j2` results are Jinja templates (gavinmcfall uses them). Their values are still useful. Ignore the outer template syntax.
- Pinned digest tags (`image@sha256:...`) are fine to copy, but note that the user may prefer a mutable tag.
- Multiple instances (for example Sonarr ×3): the search returns all variants. Check the name field (for example `sonarr-anime`, `sonarr-4k`).
- App not in kubesearch: less common apps (for example Pelican Panel) are often not indexed. Fall back to GitHub search.
- kubesearch data staleness: chunks update daily, so very new apps often do not appear yet.
