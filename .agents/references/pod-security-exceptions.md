# Pod Security Exceptions — Artemis-Cluster

`cluster-conventions.md` § Helm / app-template v5 defines the default security context for every
app, and it wins. A handful of apps cannot run under it. **This file records why**, because the manifests
carry no comments (`yaml-conventions.md` § No Comments in Manifests) and a deviation with no
recorded reason gets "fixed" back to the default and breaks the app.

The current set is the tree, not a list here:

```bash
grep -rln 'runAsNonRoot: false' kubernetes/apps/
grep -rln 'readOnlyRootFilesystem: false' kubernetes/apps/
```

## Why each one deviates

| App                              | Deviation                                                                                                                                               | Reason                                                                                                                                                                                   |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `home-automation/matter-server`  | the route-fix init container runs uid 0 with `NET_ADMIN`; the app (uid 1000) adds `NET_RAW` and sets `net.ipv4.ping_group_range: 1000 1000`             | init: same as home-assistant's. App: upstream `setcap`s `ping` with `cap_net_raw+ep`, so exec fails with EPERM once `NET_RAW` is dropped; the sysctl lets it ping over a datagram socket |
| `forgejo/buildkit`               | uid 1000, `allowPrivilegeEscalation: true`, `readOnlyRootFilesystem: false`, `SETUID`/`SETGID` added, `seccompProfile: Unconfined`, AppArmor unconfined | rootless buildkitd unshares user namespaces — see `ci.md` § buildkit                                                                                                                     |
| `kube-system/lldpd`              | uid/gid 0, `hostNetwork: true`                                                                                                                          | runs on the host network to speak LLDP on its interfaces                                                                                                                                 |
| `home-automation/home-assistant` | the route-fix init container runs uid 0 with `NET_ADMIN`                                                                                                | it deletes the pod-network IPv6 default route — see `networking.md` § Thread routing. The app container keeps the default                                                                |
| `kube-system/etcd-defrag`        | uid/gid 0, `hostPID: true`, control-plane only                                                                                                          | it defragments etcd on the host                                                                                                                                                          |

Anything not in this table that deviates is drift. Add a row when you add an exception, and say
what actually breaks under the default — "needs root" without the failure mode is not a reason.
