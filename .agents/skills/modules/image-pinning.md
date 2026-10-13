# Module: Image Pinning

Never use a bare tag — always pin with a `@sha256:` digest for reproducible deployments.

## Find tags and digest

```bash
# List available tags
crane ls <registry>/<image>

# Get the digest for a specific tag
crane digest <registry>/<image>:<tag>
```

## Result format in HelmRelease

```yaml
image:
    repository: ghcr.io/home-operations/sonarr
    tag: <version>@sha256:<digest>
```

## Verification checklist

- Cross-check the tag against the project's GitHub releases page — registries may contain orphaned pre-release tags.
- Prefer `ghcr.io/home-operations/<app>` images where available (maintained by the home-operations community and ship with correct UIDs).
- If the upstream image does not run as UID 1000, note it — `runAsUser` and `runAsGroup` in `defaultPodOptions` must match what the image expects.
