# Skill: Build Container

Build and publish a custom container image from source within the Artemis-Cluster repo when no suitable upstream image exists.

## When to use

Use this skill when an app's upstream image doesn't exist, requires entrypoint modifications for non-root k8s security contexts, or needs cluster-specific patches that are simpler to own than to fork and sync.

## Step 1 — Assess

Before creating a container, confirm:

- No usable upstream image exists on GHCR/Docker Hub
- The modification is narrow enough to maintain (2–10 lines, not a fork)
- The image won't need frequent upstream sync (otherwise fork instead)

## Step 2 — Create the Container Directory

```
containers/<app>/
├── Dockerfile
└── entrypoint.sh   (if custom entrypoint needed)
```

### Dockerfile pattern

```dockerfile
FROM <upstream-base-image> AS base-image   # optional: extract binary from upstream

FROM node:22-slim   # or appropriate slim base

ARG APP_VERSION=x.y.z

RUN apt-get update \
 && apt-get install -y --no-install-recommends tini gosu curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=base-image /path/to/binary /usr/local/bin/binary   # if extracting

WORKDIR /opt/<app>
RUN npm install "@scope/package@${APP_VERSION}" --omit=optional --no-fund --no-audit \
 && chown -R node:node /opt/<app>   # REQUIRED: prevents permission denied at runtime under non-root

COPY --chmod=0755 entrypoint.sh /usr/local/bin/<app>-entrypoint.sh

EXPOSE <port>
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS http://127.0.0.1:<port>/livez || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/<app>-entrypoint.sh"]
```

**Critical gotchas:**

- Always `chown -R node:node /opt/<app>` after `npm install` — the install runs as root during build; the pod runs as UID 1000 and will get `Permission denied` if the app writes to `node_modules` at runtime (e.g. config files, caches)
- Use `tini` as PID 1 for proper signal handling and zombie reaping
- Include `gosu` only if the entrypoint needs to drop from root to a user

### Entrypoint: non-root k8s pattern

When the upstream entrypoint assumes root (chown, gosu), adapt it to detect the running UID:

```sh
#!/bin/sh
set -eu

IS_ROOT="$([ "$(id -u)" = "0" ] && echo true || echo false)"

if [ "$IS_ROOT" = "true" ]; then
  chown -R node:node /data
  exec gosu node <app-binary> "$@"
else
  # Running as non-root (k8s fsGroup handles /data ownership)
  exec <app-binary> "$@"
fi
```

## Step 3 — Create the Forgejo Actions Workflow

```
.forgejo/workflows/build-<app>.yml
```

```yaml
---
name: Build <app>

on:
    push:
        branches:
            - main
        paths:
            - containers/<app>/**
    workflow_dispatch:

concurrency:
    group: ${{ forgejo.workflow }}-${{ forgejo.ref }}
    cancel-in-progress: true

permissions:
    contents: read
    packages: write

jobs:
    build:
        name: Build and push
        runs-on: ubuntu-latest
        steps:
            - name: Checkout
              uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

            - name: Set up Docker Buildx
              uses: docker/setup-buildx-action@b5ca514318bd6ebac0fb2aedd5d36ec1b5c232a2 # v3.10.0

            - name: Login to Forgejo registry
              uses: docker/login-action@74a5d142397b4f367a81961eba4e8cd7edddf772 # v3.4.0
              with:
                  registry: git.dcunha.io
                  username: ${{ forgejo.actor }}
                  password: ${{ secrets.CI_TOKEN }}

            - name: Build and push
              uses: docker/build-push-action@14487ce63c7a62a4a324b0bfb37086795e31c6c1 # v6.16.0
              with:
                  context: containers/<app>
                  push: true
                  tags: git.dcunha.io/exikle/<app>:<version>
                  cache-from: type=gha
                  cache-to: type=gha,mode=max
                  platforms: linux/amd64
```

**SHA pinning:** Always verify action SHAs against the actual tag — a single character typo silently breaks the build with "unable to find version". Verify with:

```bash
FORGEJO_TOKEN=$(op read "op://kubernetes/forgejo/FORGEJO_ADMIN_TOKEN")
curl -s "https://git.dcunha.io/api/v1/repos/docker/build-push-action/git/refs/tags/v6.16.0" \
  -H "Authorization: token $FORGEJO_TOKEN" | jq -r '.object.sha'
```

The workflow only triggers when `containers/<app>/**` changes. For the first run after fixing the workflow file itself (which is outside that path), trigger manually:

```bash
FORGEJO_TOKEN=$(op read "op://kubernetes/forgejo/FORGEJO_ADMIN_TOKEN")
curl -s -X POST "https://git.dcunha.io/api/v1/repos/exikle/Artemis-Cluster/actions/workflows/build-<app>.yml/dispatches" \
  -H "Authorization: token $FORGEJO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"ref": "main"}'
```

## Step 4 — Set Package Visibility

After the first successful build, the package appears at `https://git.dcunha.io/exikle/-/packages/container/<app>/`.

Forgejo packages inherit the repo's visibility by default. If the repo is public the image is public. For a private repo, add a pull secret or ensure Flux has credentials:

```yaml
# In defaultPodOptions or per-controller:
imagePullSecrets:
    - name: forgejo-registry
```

## Step 5 — Reference in HelmRelease

```yaml
image:
    repository: git.dcunha.io/exikle/<app>
    tag: <version>
```

**Version bumping:** When you update the Dockerfile, bump the tag in both `build-<app>.yml` and `helmrelease.yaml` together in the same commit. The workflow builds and pushes the new tag; Flux reconciles and pulls it.

## Step 6 — k8s Security Context

Custom containers need explicit non-root security context:

```yaml
securityContext:
    allowPrivilegeEscalation: false
    capabilities:
        drop:
            - ALL
    readOnlyRootFilesystem: false # set true only if app writes nothing at runtime
defaultPodOptions:
    securityContext:
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
        runAsGroup: 1000
        runAsNonRoot: true
        runAsUser: 1000
```

`readOnlyRootFilesystem: false` is required if the app writes config or cache into its own install directory at startup (common with npm packages).

## Common Issues

- **`Permission denied` writing to node_modules at startup**: add `chown -R node:node /opt/<app>` in Dockerfile after install
- **Build not triggering on workflow file fix**: workflow path filter excludes `.forgejo/workflows/`; trigger manually via the Forgejo API (see the `forgejo` skill, "Trigger a Workflow Run" section)
- **SHA resolution failure**: the SHA in `uses:` doesn't match the tag's commit — re-verify with `gh api`
- **Image pull error in cluster**: GHCR package is still private — make it public in package settings
