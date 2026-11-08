# Module: Image Pinning

Never use a bare tag. Always pin the image with a `@sha256:` digest, so that deployments are reproducible.

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

- Compare the tag with the GitHub releases page of the project. Registries can contain orphaned pre-release tags.
- Prefer `ghcr.io/home-operations/<app>` images where they exist. The home-operations community maintains them, and they ship with correct UIDs.
- If the upstream image does not run as UID 1000, note it. The `runAsUser` and `runAsGroup` values in `defaultPodOptions` must match the UID that the image expects.
