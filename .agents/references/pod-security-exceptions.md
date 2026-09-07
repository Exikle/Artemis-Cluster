# Pod Security Exceptions — Artemis-Cluster

`cluster-conventions.md` defines one default security context for every app: `runAsNonRoot: true`,
uid/gid 1000, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, all capabilities
dropped. A handful of apps cannot run under it. **This file records why**, because the manifests
carry no comments (`yaml-conventions.md` § No Comments in Manifests) and a deviation with no
recorded reason gets "fixed" back to the default and breaks the app.

The current set is the tree, not a list here:

```bash
grep -rln 'runAsNonRoot: false' kubernetes/apps/
grep -rln 'readOnlyRootFilesystem: false' kubernetes/apps/
```

## Why each one deviates

| App                                                       | Deviation                                                             | Reason                                                                                                                       |
| --------------------------------------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `home-automation/homebridge`                              | uid/gid 0, `fsGroup: 0`                                               | the `homebridge/homebridge` image expects root. `seccompProfile: RuntimeDefault` is kept, so syscall filtering still applies |
| `home-automation/matter-server`                           | uid 0                                                                 | the upstream image requires root                                                                                             |
| `home-automation/node-red`                                | `readOnlyRootFilesystem: false`                                       | Node-RED writes into `/data` at runtime                                                                                      |
| `home-automation/home-assistant` (`codeserver` container) | `readOnlyRootFilesystem: false`                                       | code-server writes to home directories and `/tmp`. The `app` container stays read-only                                       |
| `arcade/eco`                                              | uid/gid 0, `readOnlyRootFilesystem: false`                            | GDI+ rendering — see `arcade-eco.md`                                                                                         |
| `cortex/hermes` (`app` container)                         | uid 0 plus `CHOWN`/`DAC_OVERRIDE`/`FOWNER`/`FSETID`/`SETGID`/`SETUID` | manages ownership inside its own home directory — see `hermes.md`                                                            |
| `security/tinyauth`                                       | uid 0, `readOnlyRootFilesystem: false`                                | the sqlite session DB and the resources dir both live under `/data` — see `identity-stack.md`                                |
| `forgejo/buildkit`                                        | loose by design                                                       | it is the remote builder — see `tekton-ci.md` § buildkit                                                                     |
| `kube-system/etcd-defrag`                                 | uid/gid 0, `hostPID: true`, control-plane only                        | it defragments etcd on the host                                                                                              |
| `cortex/searxng`                                          | `runAsNonRoot: false` only (no uid override)                          | **reason not recorded.** Investigate before changing or removing it                                                          |
| `default/xbrowsersync`                                    | uid/gid 999, `readOnlyRootFilesystem: false`                          | the mongodb sidecar owns its data as 999 (the same uid `kopiur.md` records for its mover)                                    |

Anything not in this table that deviates is drift. Add a row when you add an exception, and say
what actually breaks under the default — "needs root" without the failure mode is not a reason.
