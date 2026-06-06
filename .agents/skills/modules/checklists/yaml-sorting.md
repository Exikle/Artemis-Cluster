# Checklist: YAML Sorting

Apply rules from `.agents/skills/modules/sorting.md`. Mark each item **PASS**, **FAIL**, or **N/A**.

## All files

| #   | Check                                                                                                                                          | Result |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| Y1  | Top-level order: `apiVersion → kind → metadata → spec`                                                                                         |        |
| Y2  | `metadata` order: `name → namespace → annotations → labels` (namespace omitted on app manifests — injected by Kustomization `targetNamespace`) |        |
| Y3  | `enabled` is the first field in every section that has it                                                                                      |        |
| Y4  | All other fields at every nesting level are alphabetical unless a specific rule applies                                                        |        |
| Y5  | YAML anchors (`&foo`) appear before any alias (`*foo`) that references them                                                                    |        |
| Y6  | YAML inside string values (e.g. ConfigMap data keys) is NOT sorted                                                                             |        |

## HelmRelease `spec`

| #   | Check                                                                                                                      | Result |
| --- | -------------------------------------------------------------------------------------------------------------------------- | ------ |
| Y7  | `spec` order: `chartRef → interval → dependsOn → install → upgrade → values`                                               |        |
| Y8  | `spec.values` order: `defaultPodOptions` first (if present), then alphabetical                                             |        |
| Y9  | Siblings within `persistence`, `service`, `route`, `configMaps` are NOT required to be sorted — only keys within each item |        |

## Controllers

| #   | Check                                                                                                            | Result |
| --- | ---------------------------------------------------------------------------------------------------------------- | ------ |
| Y10 | `controllers.*` order: `type → annotations → labels → <controller-specific> → pod → initContainers → containers` |        |

## Containers / initContainers

| #   | Check                                                   | Result |
| --- | ------------------------------------------------------- | ------ |
| Y11 | Container block order: `image` first, then alphabetical |        |
| Y12 | `resources` order: `requests` before `limits`           |        |

## Services

| #   | Check                                                                  | Result |
| --- | ---------------------------------------------------------------------- | ------ |
| Y13 | `service.*` item order: `type → annotations → labels → <alphabetical>` |        |

## Persistence

| #   | Check                                                                                                                    | Result |
| --- | ------------------------------------------------------------------------------------------------------------------------ | ------ |
| Y14 | `persistence.*` item order: `type → annotations → labels → <alphabetical> → globalMounts → advancedMounts` (mounts last) |        |
