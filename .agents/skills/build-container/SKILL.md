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

## Step 3 — Create the GitHub Actions Workflow

```
.github/workflows/build-<app>.yml
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
    group: ${{ github.workflow }}-${{ github.ref }}
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
              uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

            - name: Set up Docker Buildx
              uses: docker/setup-buildx-action@b5ca514318bd6ebac0fb2aedd5d36ec1b5c232a2 # v3.10.0

            - name: Login to GHCR
              uses: docker/login-action@74a5d142397b4f367a81961eba4e8cd7edddf772 # v3.4.0
              with:
                  registry: ghcr.io
                  username: ${{ github.actor }}
                  password: ${{ secrets.GITHUB_TOKEN }}

            - name: Build and push
              uses: docker/build-push-action@14487ce63c7a62a4a324b0bfb37086795e31c6c1 # v6.16.0
              with:
                  context: containers/<app>
                  push: true
                  tags: ghcr.io/exikle/<app>:<version>
                  cache-from: type=gha
                  cache-to: type=gha,mode=max
                  platforms: linux/amd64
```

**SHA pinning:** Always verify action SHAs against the actual tag — a single character typo silently breaks the build with "unable to find version". Verify with:

```bash
mise exec -- gh api repos/docker/build-push-action/git/refs/tags/v6.16.0 --jq '.object.sha'
```

The workflow only triggers when `containers/<app>/**` changes. For the first run after fixing the workflow file itself (which is outside that path), trigger manually:

```bash
mise exec -- gh workflow run "Build <app>" --repo Exikle/Artemis-Cluster --ref main
```

## Step 4 — Make the GHCR Package Public

After the first successful build:

1. Go to `https://github.com/users/Exikle/packages/container/<app>/settings`
2. Danger Zone → Change visibility → Public
3. Type the package name to confirm

The package won't appear until the first build completes. Flux cannot pull private GHCR images without imagePullSecrets.

## Step 5 — Reference in HelmRelease

```yaml
image:
    repository: ghcr.io/exikle/<app>
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
- **Build not triggering on workflow file fix**: workflow path filter excludes `.github/`; trigger manually with `gh workflow run`
- **SHA resolution failure**: the SHA in `uses:` doesn't match the tag's commit — re-verify with `gh api`
- **Image pull error in cluster**: GHCR package is still private — make it public in package settings
