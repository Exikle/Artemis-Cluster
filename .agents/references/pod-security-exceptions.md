# Pod Security Exceptions — home-infra

`cluster-conventions.md` § Helm / app-template v5 defines the default security context for every
app, and it wins. A handful of apps cannot run under it. This file records the reason for each
deviation. The manifests carry no comments (`yaml-conventions.md` § No Comments in Manifests), and
someone will "fix" a deviation with no recorded reason back to the default and break the app.

The tree gives the current set, not a list here:

```bash
grep -rln 'runAsNonRoot: false' clusters/artemis/kubernetes/apps/
grep -rln 'readOnlyRootFilesystem: false' clusters/artemis/kubernetes/apps/
```

## Why each one deviates

| App                              | Deviation                                                                                                                                               | Reason                                                                                                                                                                                                                                             |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `home-automation/matter-server`  | the route-fix init container runs uid 0 with `NET_ADMIN`; the app (uid 1000) adds `NET_RAW` and sets `net.ipv4.ping_group_range: 1000 1000`             | init: same as home-assistant's. App: upstream `setcap`s `ping` with `cap_net_raw+ep`, so exec fails with EPERM once `NET_RAW` is dropped; the sysctl lets it ping over a datagram socket                                                           |
| `default/bambuddy`               | the app (uid 1000) adds `NET_BIND_SERVICE`                                                                                                              | The upstream image runs `setcap cap_net_bind_service=+ep` on `python3`, which runs the whole app. The matter-server row shows that exec of such a binary fails with EPERM when the capability is dropped. This failure was not tested for bambuddy |
| `forgejo/buildkit`               | uid 1000, `allowPrivilegeEscalation: true`, `readOnlyRootFilesystem: false`, `SETUID`/`SETGID` added, `seccompProfile: Unconfined`, AppArmor unconfined | rootless buildkitd unshares user namespaces. See `ci.md` § buildkit                                                                                                                                                                                |
| `kube-system/lldpd`              | uid/gid 0, `hostNetwork: true`                                                                                                                          | runs on the host network to speak LLDP on its interfaces                                                                                                                                                                                           |
| `home-automation/home-assistant` | the route-fix init container runs uid 0 with `NET_ADMIN`                                                                                                | it deletes the pod-network IPv6 default route. See `networking.md` § Thread routing. The app container keeps the default                                                                                                                           |
| `kube-system/etcd-defrag`        | uid/gid 60, `hostNetwork: true`, control-plane only                                                                                                     | it reaches etcd on `127.0.0.1:2379` with the certs in `/system/secrets/etcd`, which Talos owns as the etcd user (uid 60); root without `DAC_OVERRIDE` gets permission denied on them                                                               |

Anything that deviates and is not in this table is drift. Add a row when you add an exception, and
say what actually breaks under the default. "Needs root" without the failure mode is not a reason.
