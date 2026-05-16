# Skill: Kubesearch — Find Home-Ops Examples

Search GitHub for real HelmRelease examples from other home-ops clusters and adapt the best one to Artemis-Cluster conventions.

## Step 1 — Identify the Query

Confirm the app name to search for (e.g. `sonarr`, `paperless-ngx`, `immich`). If the user is mid-task (e.g. deploying an app), the query is the app or chart name being deployed.

## Step 2 — Search GitHub for HelmRelease Examples

Search for `helmrelease.yaml` files under `kubernetes/apps` paths (standard home-ops layout):

```bash
PATH="$HOME/.local/share/mise/shims:$PATH" gh api \
  "search/code?q=<app>+filename:helmrelease.yaml+path:kubernetes/apps&per_page=10" \
  --jq '.items[] | {repo: .repository.full_name, path: .path, url: .html_url}'
```

If no results, broaden by dropping the path filter:

```bash
PATH="$HOME/.local/share/mise/shims:$PATH" gh api \
  "search/code?q=<app>+filename:helmrelease.yaml&per_page=10" \
  --jq '.items[] | {repo: .repository.full_name, path: .path, url: .html_url}'
```

**Prioritise results** in this order:

1. `path` contains `kubernetes/apps` (home-ops layout)
2. Well-known repos: `onedr0p/home-ops`, `gavinmcfall/home-ops`, `bjw-s/home-ops`
3. Highest star count (visible in `.repository.stargazers_count`)

## Step 3 — Fetch the Top Result

Extract owner/repo and path from the chosen result, then fetch the raw content:

```bash
REPO="<owner>/<repo>"
FILE="<path/to/helmrelease.yaml>"

PATH="$HOME/.local/share/mise/shims:$PATH" gh api \
  "repos/${REPO}/contents/${FILE}" \
  --jq '.content' | base64 -d
```

Fetch 1–2 results if the first looks incomplete (e.g. it references other files or is a template stub like `.yaml.j2`).

## Step 4 — Present and Adapt

Show the fetched YAML and note the source URL. Then identify the key patterns:

- **Image**: repository + tag or digest
- **Environment variables**: app-specific env vars to carry forward
- **Ports**: HTTP port number
- **Persistence**: mount paths and PVC usage
- **Secrets**: what env vars are sourced from secrets
- **Security context**: `runAsUser`, `readOnlyRootFilesystem`, etc.

Then adapt to Artemis-Cluster conventions:

| Theirs                  | Artemis equivalent                                                              |
| ----------------------- | ------------------------------------------------------------------------------- |
| Any chart source        | `OCIRepository` pointing to `oci://ghcr.io/bjw-s-labs/helm/app-template` (v5)   |
| `secretRef` / `envFrom` | `ExternalSecret` via `onepassword-connect` ClusterSecretStore                   |
| `Ingress`               | `HTTPRoute` via `internal-gateway` or `external-gateway` in `network` namespace |
| `TZ: America/New_York`  | `TZ: America/Toronto`                                                           |
| Any namespace           | Match user's target namespace for this cluster                                  |

If the source repo already uses `app-template`, carry their `controllers`/`containers`/`persistence` structure directly — just update image, TZ, and secrets pattern.

## Common Issues / Gotchas

- **`.yaml.j2` results**: these are Jinja templates (gavinmcfall/home-ops uses them) — still useful for values, but skip the outer template syntax
- **Pinned digest tags** (`image@sha256:...`): fine to copy, but note the user may want a mutable tag for easier updates
- **`path:` filter misses some repos**: some clusters use `cluster/apps` or `apps/` — broaden the search if needed
- **Rate limits**: `gh api` uses your authenticated token (higher limit than anonymous). If you hit a limit, wait and retry.
- **Multiple instances** (e.g. Sonarr ×3): search returns any instance — check the values for instance-specific env vars like `SONARR__APP__INSTANCENAME`
