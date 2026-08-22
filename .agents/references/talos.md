# Reference: Talos — Artemis-Cluster

## Running Versions

Verified live 2026-08-21. Anything in this file that names `v1.14.0-beta.1` is describing a
**past incident on that build**, not the current state.

|                           | Value                                                                                    |
| ------------------------- | ---------------------------------------------------------------------------------------- |
| Talos (all seven nodes)   | `v1.14.0-rc.1`                                                                           |
| Kubernetes                | `v1.36.4`                                                                                |
| Arch                      | `amd64` (Frostlink is `arm64` — schematics and images do not cross)                      |
| Installer image in git    | `talos/cluster.yaml.j2` → `factory.talos.dev/installer/{{ ENV.SCHEMATIC }}:v1.14.0-rc.1` |
| tuppr `TalosUpgrade`      | `v1.14.0-rc.1`                                                                           |
| tuppr `KubernetesUpgrade` | `v1.36.4`                                                                                |
| talosctl pin              | `.mise/config.toml` → `talos = "1.14.0-rc.1"`                                            |

Those five must move together. `talosctl` decodes config documents client-side, so a client older
than the cluster rejects a v1.14 document (`"KubeTalosAPIAccessConfig" "v1alpha1": not registered`)
before the node ever sees it — always `mise exec -- talosctl`.

## Config Management

```bash
just talos render-config <node>     # render node config from template
just talos validate [node]          # render + talosctl validate; all nodes if omitted, exits non-zero on failure
just talos diff-node <node>         # apply-config --dry-run: what would change on that node
just talos apply-node <node>        # apply config to node (live, no reboot)
```

Run `validate` after editing a template and `diff-node` before `apply-node` — an empty
diff-node across all nodes is the check that the cluster and git actually agree.

`render-config` layers three Jinja2 templates through `talosctl machineconfig patch`:

1. `talos/cluster.yaml.j2` — everything shared by every node
2. `talos/<controlplane|worker>.yaml.j2` — selected by `machine.type` in the node file
   (`just talos machine-type`), which is why every node file must declare it
3. `talos/nodes/<node>.yaml.j2` — hostname, labels, install disk

Machine-type differences used to be `{% if ENV.IS_CONTROLLER %}` blocks in one file; the
split is purely structural and the rendered output per node is unchanged.

**Patching the v1alpha1 document merges per struct field, and some structs are leaves.**
`PEMEncodedCertificateAndKey` is one: a patch that sets only `ca.key` replaces the whole
pair and renders `crt: ""` — a control plane with no CA certificate, which validates
clean. Always carry `crt` and `key` together in whichever file sets either. Typed
documents (`kind:`) merge by kind + `name`, so partial overrides there are safe.

The installer image is defined **once**, in `cluster.yaml.j2`'s `UnattendedInstallConfig`, as
`factory.talos.dev/installer/{{ ENV.SCHEMATIC }}:<version>`. `render-config` derives the
schematic type from the node name, resolves it against the Image Factory, and injects the ID.
The mapping lives in `talos/mod.just` § `schematic-type`:

| Node name pattern | Schematic      |
| ----------------- | -------------- |
| `*-cp-*`          | `controlplane` |
| `*-gpu-*`         | `gpu`          |
| `ymir`            | `metal`        |
| anything else     | `worker`       |

### `metal` and `controlplane` resolve to the SAME factory ID

`talos/schematics/metal.yaml` and `talos/schematics/controlplane.yaml` are byte-for-byte
identical in content today — same six extensions, same kernel args — so the Image Factory returns
one ID for both. Live node annotations (`extensions.talos.dev/schematic`):

| Nodes                           | Schematic ID        | Source file                        |
| ------------------------------- | ------------------- | ---------------------------------- |
| `talos-cp-01/02/03`, **`ymir`** | `95a6e945f92d3d58…` | `controlplane.yaml` ≡ `metal.yaml` |
| `talos-w-01`, `talos-w-02`      | `35664373b1542556…` | `worker.yaml`                      |
| `talos-gpu-01`                  | `4538d48192765b1d…` | `gpu.yaml`                         |

Two consequences, neither obvious:

- **You cannot tell `ymir` from a control plane by its annotation.** Do not use the node's
  reported schematic ID to infer which schematic _file_ a node is meant to track — use
  `just talos schematic-type <node>`, which is the only authority.
- **A change to `controlplane.yaml` alone silently changes `ymir` too**, and vice versa, because
  both files still hash to one ID until their contents actually diverge. The moment one gains an
  extension the other lacks, the IDs split and `ymir` starts tracking a distinct image. That is
  intended — just do not be surprised when a "control-plane-only" schematic edit reboots the
  bare-metal worker as well.

`metal` is `worker` **minus** `siderolabs/qemu-guest-agent`. On bare metal that service can
never come up and Talos blocks its boot sequence waiting for it until the phase times out and
the node reboots — roughly every 70 minutes. Bare-metal workers must get `metal`, never
`worker`. Node files carry only the disk
selector and wipe flag. Never hardcode a schematic hash in a node file — that pattern let
`schematics/controlplane.yaml` silently diverge from what the CP nodes actually ran.

## Extension Changes

Extensions require a new schematic ID and node reboot. The ID is now computed at render
time, so there is nothing to hand-update:

1. Edit the schematic in `talos/schematics/<controlplane|worker|gpu|metal>.yaml` — there are **four**, not three; `metal.yaml` is the one usually forgotten
2. `just talos apply-node <node> --mode=reboot`

To see the image a node will get without applying:
`just talos render-config <node> | yq 'select(.kind == "UnattendedInstallConfig") | .installer.image'`.

## Config Format (Talos 1.14 multi-document)

The templates are on the 1.14 typed-document layout. Everything still in v1alpha1 is there
for a concrete reason — audited against the full 1.14 document catalogue 2026-08-03. Do not
"finish" the migration without re-checking these against the 1.14 stable reference:

| Stays in v1alpha1                                    | Why                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `machine.token`, `machine.ca`, `machine.type`        | no document equivalent exists — only the _Kubernetes_ CAs got documents, not the machine CA                                                                                                                                                                                                                                                                                                                             |
| `machine.features.diskQuotaSupport`                  | **no document exists.** Upstream's `VolumeConfig` reference states outright: "project quota support is configured via machine features". Not an oversight — do not go looking for a `VolumeConfig` field for this.                                                                                                                                                                                                      |
| `cluster.etcd`                                       | **no etcd document exists at all** in 1.14 — there is no `etcd/` group in the config reference. `advertisedSubnets` and `extraArgs` have nowhere else to live.                                                                                                                                                                                                                                                          |
| PKI (`cluster.ca`, `aggregatorCA`, `serviceAccount`) | the new CA documents parse PEM; the 1Password items hold base64-DER as v1alpha1 expects                                                                                                                                                                                                                                                                                                                                 |
| cluster identity (`cluster.id`/`secret`)             | `.cluster.discovery` is unset → zero value → discovery is **off** cluster-wide (`get discoveryconfig` is all-false, `get members` empty, so `resolveMemberNames` is inert). `DiscoveryServiceConfig` is the only thing that populates ServiceEndpoints, so adding it would switch discovery on and register every node with public discovery.talos.dev. Not a refactor. The Kubernetes registry has no document at all. |
| `cluster.clusterName`, `cluster.controlPlane`        | `KubeClusterConfig` — see the DO-NOT-MIGRATE warning below; this one caused an outage                                                                                                                                                                                                                                                                                                                                   |

`machine.install` was migrated to `UnattendedInstallConfig` on 2026-08-03. The controller
"mirrors the legacy .machine.install install behavior" but short-circuits on
`Machine().Installed()`, so the document is inert on a provisioned node — it only fires
against a machine booted from the ISO in maintenance mode. Legacy `diskSelector.model`
globs and bare `disk:` paths became CEL (`disk.model == "..." && disk.transport == "sata"`,
`disk.dev_path == "/dev/vda"`). The image path stays `installer/` rather than upstream's
`metal-installer/` because the tuppr `factory-url` annotation pins the same prefix; both
must move together.

**The templates are kept comment-free — every "why" for them is in this section.** If a line
in `talos/*.j2` looks redundant or wrong, it is almost certainly listed below; check here
before deleting it.

Cost real downtime when gotten wrong:

- **Never migrate `.cluster.controlPlane` to `KubeClusterConfig` on 1.14.0-beta.1.** Removing
  it leaves the field nil, and the v1alpha1→k8s bridge still calls `(*ClusterConfig).Endpoint()`
  unguarded from `K8sServiceAccountConfig()` (`v1alpha1_k8s_bridge.go:331` →
  `v1alpha1_clusterconfig.go:66`). That panics `secrets.RootKubernetesController`, which stops
  rendering the control plane static pods — every CP comes back from a reboot with no
  kube-apiserver. Took the whole API down 2026-08-03. The node stays Ready, so it only bites on
  reboot; verify with `talosctl get staticpods`.
    - Consequence: `cluster.yaml.j2` sets the worker endpoint and `controlplane.yaml.j2`
      overrides it, so `.cluster.controlPlane` is never absent from a rendered config.
- **Disabled components still need an explicit `image:`.** 1.14.0-beta.1's `images.List()`
  calls `mustParseTag` on every component unconditionally, so `KubeProxyConfig` /
  `KubeCoreDNSConfig` with `enabled: false` and no `image:` yields `""` and panic-loops
  `k8s.ControlPlaneBootstrapManifestsController` — which also stalls the manifests it renders
  unconditionally (CSR approve/renew RBAC, kubelet bootstrap token, kube-config-in-cluster,
  `system:talos-nodes`, the `serviceaccounts.talos.dev` CRD). Values are Talos' own defaults so
  nothing is pulled; the components stay disabled (kube-proxy → Cilium, CoreDNS → our own
  `kube-system/coredns` HelmRelease). A Ready cluster hides this — check `talosctl dmesg`.
- `nodeIP` must be in `KubeNodeConfig`, never `machine.kubelet.nodeIP` — setting both errors.
- Using `KubeAPIServerConfig` makes `KubeAuthorizerConfig` (Node + RBAC) **mandatory**; without
  them kube-apiserver exits with "authorizers: Required value: at least one authorization mode
  must be defined".
- It also makes `KubeAuthenticationConfig` mandatory — Talos writes an empty
  authentication-config.yaml otherwise and the apiserver dies on "Object 'Kind' is missing".
- `KubeNodeConfig.taints: {}` (empty **map**, a list fails to decode) replaces
  `.cluster.allowSchedulingOnControlPlanes: true`. 1.14 lists the controlplane NoSchedule taint
  explicitly instead of defaulting it, and this cluster runs workloads on the CPs.
- `KubeEtcdEncryptionConfig` secretbox key must stay named `key2` — the name is part of every
  encrypted secret's ciphertext prefix. Renaming makes existing secrets undecryptable.
- Absence of a `KubeFlannelCNIConfig` document is the new `cluster.network.cni.name: none`.

Quieter ones:

- **There is no `TimeSyncConfig` document, on purpose.** Talos always emits a `default` layer
  time server (`constants.DefaultNTPServer` = `time.cloudflare.com`) with `useNTS: true`, and
  `useNTS` only defaults to true when no NTP config is provided at all. Writing an explicit
  `TimeSyncConfig` without `useNTS: true` therefore _disables_ NTS silently. The UCG-Max at
  10.10.99.1 does not run an NTP daemon (UDP/123 returns connection refused) and does not send
  DHCP option 42, so it was only ever a dead first entry — and NTS requires hostnames, not IPs,
  so it could not have stayed anyway. Verify with
  `talosctl get timeserverspecs --namespace network-config` (shows the layers) and look for
  "established NTS session" in `dmesg`. Layer precedence: default → cmdline → platform →
  operator (DHCP) → configuration.

- Both tuppr annotations on `KubeNodeConfig` are required to override its schematic guard —
  `tuppr.home-operations.com/schematic` is only read inside the `factory-url` branch of
  `buildTalosUpgradeImage`, so it is a no-op alone. Safe only because each new schematic is a
  superset of the running one; re-check before a schematic **removes** an extension.
- `SecurityProfileConfig.workloadIsolation: true` must be stated explicitly. 1.14 defaults it on
  for new clusters only; upgraded clusters (this one) keep shared namespaces until the document
  exists. Applying it restarts CRI + kubelet + all pods, no reboot. Documented casualty is the
  in-tree iSCSI volume plugin — we use Ceph CSI and in-tree NFS, neither needs a host daemon.
- `KubeTalosAPIAccessConfig` has no `enabled` field; the document's presence is what turns it on.
- `disableManifestsDirectory` is deliberately absent — v1alpha1 marks it "locked to true in
  multi-doc config", so it is both unnecessary and impossible to set. It was the last thing
  pinning the kubelet block to v1alpha1. `extraConfig` is spelled `config` on `KubeletConfig`.
- `machine.features.rbac` and `apidCheckExtKeyUsage` no longer exist in the 1.14 v1alpha1 schema.

## 1.14 Documents Considered and NOT Adopted

Audited against the full 1.14 catalogue 2026-08-03. These are deliberate omissions, not gaps
— re-reading this list is cheaper than rediscovering why each was skipped:

| Document                                             | Why not                                                                                                                                                                 |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TimeSyncConfig`                                     | writing it disables NTS — see the note above                                                                                                                            |
| `DiscoveryServiceConfig` / `DiscoveryIdentityConfig` | would switch discovery on, not refactor it                                                                                                                              |
| `KubeClusterConfig`                                  | nil-deref outage on beta.1                                                                                                                                              |
| `OOMConfig`                                          | 1.14's userspace OOM handler, driven by CEL trigger/ranking expressions. Plausibly relevant to the rook-ceph mgr OOM loop — **unevaluated**, would need its own session |
| `KmsgLogConfig` / `EventSinkConfig`                  | could ship kernel logs and Talos events to VictoriaLogs over tcp/udp. Genuinely attractive here, just not wired up yet                                                  |
| `KubeSpanConfig`                                     | single site, no mesh needed                                                                                                                                             |
| `RegistryMirrorConfig` / `ImageCacheConfig`          | no pull-rate or bandwidth problem to solve                                                                                                                              |
| `SwapVolumeConfig` / `ZswapConfig`                   | no swap on these nodes by design                                                                                                                                        |
| `UserVolumeConfig`                                   | no local-path storage; everything is Ceph or NFS                                                                                                                        |
| `NetworkRuleConfig` / `NetworkDefaultActionConfig`   | host firewall — not attempted; would need care not to lock out the API                                                                                                  |

## kata-containers — provisioned but unused

All four schematics ship `siderolabs/kata-containers` (3.32.0 on the nodes) and a `kata-qemu`
RuntimeClass exists in the cluster, but **no pod uses it** and nothing in `talos/` wires a
containerd runtime handler for it — the extension supplies its own. This is a follow-on to the
`workloadIsolation` work and is parked for a dedicated session; treat the extension as
deliberate, not leftover. Removing it from a schematic would be a schematic change requiring
reboots, and the tuppr guard assumes new schematics are supersets of the running one.

## Automated Upgrades — owned by tuppr

`tuppr` runs in the `system-upgrade` namespace and owns both Talos and Kubernetes upgrades.
Upgrades are declarative: edit the version in
`kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (or `kubernetesupgrade.yaml`),
merge, and tuppr rolls the cluster. Do not upgrade a node by hand while tuppr is healthy.

Live configuration (`kubernetes/apps/system-upgrade/tuppr/upgrades/`, verified 2026-08-21):

| Setting                     | Value                                                                                                 | Why                                                                                                                                                                                |
| --------------------------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TalosUpgrade.version`      | `v1.14.0-rc.1`                                                                                        | Renovate-tracked via `custom.talos-factory`, automerge OFF                                                                                                                         |
| `policy.rebootMode`         | `powercycle`                                                                                          |                                                                                                                                                                                    |
| `policy.timeout`            | `45m`                                                                                                 | the 30m default was tight — `talos-w-01` timed out with the node still on the old version, and factory.talos.dev bakes installer images on first request, which stalled a pre-pull |
| `drain.enabled`             | `true`                                                                                                | seven nodes, so there **is** somewhere to drain to (Frostlink has not)                                                                                                             |
| Talos health gates          | Node `Ready`, kopiur `Snapshot` not Pending/Running, `CephCluster` in `HEALTH_OK`/`HEALTH_WARN` (10m) | never roll the next node onto a degraded Ceph                                                                                                                                      |
| `KubernetesUpgrade.version` | `v1.36.4`                                                                                             |                                                                                                                                                                                    |
| K8s health gates            | kopiur `Snapshot` idle, `CephCluster` `HEALTH_OK` only                                                | stricter than the Talos gate — a K8s upgrade has no reboot to excuse a WARN                                                                                                        |

### tuppr rebuilds from the node's RECORDED schematic

tuppr rewrites `.machine.install.image` to
`factory.talos.dev/installer/<schematic>:<version>` using the schematic the **node reports at
runtime**, not the one in `talos/schematics/`. Extensions therefore survive an upgrade without
any repo change — and a **stale recorded schematic silently reinstalls an extension you removed
from git**. Removing an extension is a two-step operation: edit the schematic file, then
`just talos apply-node <node> --mode=reboot` so the node re-records the new ID _before_ the next
tuppr run. Editing the schematic file alone changes nothing about what tuppr installs.

The image path stays `installer/` rather than upstream's `metal-installer/` because the tuppr
`factory-url` annotation pins the same prefix — **both must move together.** (Frostlink's tuppr
uses `metal-installer`; the two clusters are deliberately not aligned here.)

Both tuppr annotations on `KubeNodeConfig` are required to override the schematic guard —
`tuppr.home-operations.com/schematic` is only read inside the `factory-url` branch of
`buildTalosUpgradeImage`, so it is a no-op alone. Safe only because each new schematic here is a
superset of the running one; re-check before a schematic **removes** an extension.

tuppr triggers on `currentVersion != targetVersion` — **not** a "newer than" check, and there is
no downgrade guard. Never bump a version out of band while Flux still serves the old value from
git: the next reconcile reverts the CR and tuppr downgrades the cluster.

## Node Reference

| Node           | Role           | Hardware                                        | IP         |
| -------------- | -------------- | ----------------------------------------------- | ---------- |
| `talos-cp-01`  | Control plane  | Lenovo M710q                                    | 10.10.99.x |
| `talos-cp-02`  | Control plane  | Lenovo M710q                                    | 10.10.99.x |
| `talos-cp-03`  | Control plane  | Lenovo M710q                                    | 10.10.99.x |
| `talos-w-01`   | Worker         | Proxmox VM (pantheon)                           | 10.10.99.x |
| `talos-w-02`   | Worker         | Proxmox VM (pantheon)                           | 10.10.99.x |
| `talos-gpu-01` | Worker + GPU   | Proxmox VM, Arc A380 passthrough                | 10.10.99.x |
| `ymir`         | Worker (metal) | Gigabyte C246N-WU2, Xeon E-2124G, UHD P630 iGPU | 10.10.99.x |

**Seven nodes, not six.** `ymir` is a bare-metal worker (`talos/nodes/ymir.yaml.j2`) and is the
only node on the `metal` schematic. Anything that counts nodes — a tuppr blast-radius argument,
a drain plan — has to count seven. Node files are the ground truth: `ls talos/nodes/`.
