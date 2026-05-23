# Checklist: app/ocirepository.yaml

Mark each item **PASS**, **FAIL**, or **N/A**.

| # | Check | Result |
| --- | --- | --- |
| O1 | Schema comment present: `# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json` | |
| O2 | `apiVersion: source.toolkit.fluxcd.io/v1` (not `v1beta2`) | |
| O3 | `url: oci://ghcr.io/bjw-s-labs/helm/app-template` (`bjw-s-labs`, not `bjw-s`) | |
| O4 | `layerSelector.mediaType` and `layerSelector.operation: copy` both present | |
| O5 | `ref.tag` is set to a valid app-template version (e.g. `5.0.1`) | |
| O6 | `name` matches the app name — not shared with another app | |
| O7 | Metadata has `name` only — no `namespace` (Kustomization `targetNamespace` injects it) | |
| O8 | Top-level field order: `apiVersion → kind → metadata → spec` | |
