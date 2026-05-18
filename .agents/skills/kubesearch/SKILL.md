# Skill: Kubesearch — Find Home-Ops Examples

Search [kubesearch.dev](https://kubesearch.dev) for real HelmRelease examples from other home-ops clusters and adapt the best one to Artemis-Cluster conventions.

kubesearch.dev indexes repos tagged `k8s-at-home` / `kubesearch` on GitHub and GitLab. Its search field is client-side JavaScript that loads static JSON files — we replicate that here directly.

## Step 1 — Identify the Query

Confirm the app name to search for (e.g. `sonarr`, `paperless-ngx`, `immich`). If mid-task (e.g. deploying an app), the query is the app or chart name being deployed.

## Step 2 — Search kubesearch.dev

Download all data chunks in parallel and filter by app name (substring match):

```bash
APP="<app-name>"
seq 0 84 | xargs -P8 -I{} sh -c "
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

**If 0 results** — the app isn't indexed (less common or not tagged `k8s-at-home`). Fall back to GitHub:

```bash
gh api "search/code?q=<app>+filename:helmrelease.yaml+path:kubernetes/apps&per_page=10" \
  --jq '.items[] | {repo: .repository.full_name, path: .path, url: .html_url}'
```

**Prioritise results** in this order:

1. Highest star count (kubesearch sorts this naturally)
2. Well-known repos: `onedr0p/home-ops`, `gavinmcfall/home-ops`, `bjw-s/home-ops`, `drag0n141/home-ops`
3. `path` contains `kubernetes/apps` (home-ops layout)

## Step 3 — Fetch the Top Result

Extract owner/repo and path from the chosen URL, then fetch raw content:

```bash
REPO="<owner>/<repo>"
FILE="<path/to/helmrelease.yaml>"

gh api "repos/${REPO}/contents/${FILE}" \
  --jq '.content' | base64 -d
```

Fetch 1–2 results if the first looks incomplete (stub, `.yaml.j2` template, or references other files).

## Step 4 — Present and Adapt

Show the fetched YAML and note the source URL. Identify the key patterns:

- **Image**: repository + tag or digest
- **Environment variables**: app-specific env vars to carry forward
- **Ports**: HTTP port number
- **Persistence**: mount paths and PVC usage
- **Secrets**: what env vars are sourced from secrets
- **Security context**: `runAsUser`, `readOnlyRootFilesystem`, etc.
- **Database/cache dependencies**: flag any `dependsOn: dragonfly-cluster` or `dependsOn: mariadb` — these require adaptation to the silo pattern (see below)

Adapt to Artemis-Cluster conventions:

| Theirs                                      | Artemis equivalent                                                                    |
| ------------------------------------------- | ------------------------------------------------------------------------------------- |
| `HelmRepository` + `chart:`                 | Standalone `OCIRepository` → `oci://ghcr.io/bjw-s-labs/helm/app-template` v5.0.0      |
| Any `TZ:` env var                           | Remove — k8tz handles timezone cluster-wide                                           |
| `secretRef` / `envFrom`                     | `ExternalSecret` via `onepassword-connect` ClusterSecretStore                         |
| `Ingress`                                   | `HTTPRoute` inline in helmrelease values via `internal-gateway` or `external-gateway` |
| `dependsOn: mariadb` or `dragonfly-cluster` | Silo pattern: SQLite if supported, else app-specific CNPG postgres or sidecar Redis   |
| Any namespace                               | Match user's target namespace for this cluster                                        |

If the source already uses `app-template`, carry their `controllers`/`containers`/`persistence` structure directly — just update image and secrets pattern.

## Common Issues / Gotchas

- **`.yaml.j2` results**: Jinja templates (gavinmcfall uses them) — still useful for values, ignore the outer template syntax
- **Pinned digest tags** (`image@sha256:...`): fine to copy, but note user may prefer a mutable tag
- **Multiple instances** (e.g. Sonarr ×3): search returns all variants — check name field (e.g. `sonarr-anime`, `sonarr-4k`)
- **App not in kubesearch**: less common apps (e.g. Pelican Panel) may not be indexed — fall back to GitHub search
- **kubesearch data staleness**: chunks update daily; very new apps may not appear yet
