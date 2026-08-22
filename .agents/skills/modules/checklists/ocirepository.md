# Checklist: app/ocirepository.yaml

Mark each item **PASS**, **FAIL**, or **N/A**.

| #   | Check                                                                                                                                            | Result |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------ |
| O1  | Schema comment present: `# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json` |        |
| O2  | `apiVersion: source.toolkit.fluxcd.io/v1` (not `v1beta2`)                                                                                        |        |
| O3  | `url: oci://ghcr.io/bjw-s-labs/helm/app-template` (`bjw-s-labs`, not `bjw-s`)                                                                    |        |
| O4  | `layerSelector.mediaType` and `layerSelector.operation: copy` both present                                                                       |        |
| O5  | `ref.tag` matches the fleet-wide app-template version — currently `5.1.0`, not `5.0.1`. Verify against the live tree, Renovate moves this        |        |
| O6  | `name` matches the app name — not shared with another app                                                                                        |        |
| O7  | Metadata has `name` only — no `namespace` (Kustomization `targetNamespace` injects it)                                                           |        |
| O8  | Top-level field order: `apiVersion → kind → metadata → spec`                                                                                     |        |
| O9  | `spec` fields alphabetical: `interval → layerSelector → ref → url`                                                                               |        |
