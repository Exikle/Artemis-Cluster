# Reference: Talos — Artemis-Cluster

## Running Versions

Anything in this file that names `v1.14.0-beta.1` describes a bug on that build, not the
current state.

Do not restate the versions here. These places hold the version, and they must move together. Read
them, and do not trust a doc:

```bash
kubectl get nodes -o wide                      # live Talos + kubelet version
grep -n installer talos/cluster.yaml.j2        # installer image in git
grep -rn version kubernetes/apps/system-upgrade/tuppr/upgrades/   # both tuppr CRs
grep -n '^talos' .mise/config.toml             # talosctl pin
```

`talosctl` decodes config documents client-side. A client that is older than the cluster rejects a
v1.14 document (`"KubeTalosAPIAccessConfig" "v1alpha1": not registered`) before the node ever sees
it. So always run `talosctl` **from inside this repo**, where the mise shim resolves the pinned
version. If you run it from elsewhere, you get the global install, which is older. You do not need a
`mise exec --` wrapper. The shims are on PATH through `~/.zshenv`, and they resolve the repo pin
from the working directory, in non-interactive `sh` too.

## Config Management

```bash
just talos render-config <node>     # render node config from template
just talos validate [node]          # render + talosctl validate; all nodes if omitted, exits non-zero on failure
just talos diff-node <node>         # apply-config --dry-run: what would change on that node
just talos apply-node <node>        # apply config to node (live, no reboot)
```

Run `validate` after you edit a template, and run `diff-node` before `apply-node`. An empty
diff-node across all nodes is the check that the cluster and git actually agree.

`render-config` layers three Jinja2 templates through `talosctl machineconfig patch`:

1. `talos/cluster.yaml.j2` — everything shared by every node
2. `talos/<controlplane|worker>.yaml.j2` — selected by `machine.type` in the node file
   (`just talos machine-type`), which is why every node file must declare it
3. `talos/nodes/<node>.yaml.j2` — hostname, labels, install disk

Patching the v1alpha1 document merges per struct field, and some structs are leaves.
`PEMEncodedCertificateAndKey` is one. A patch that sets only `ca.key` replaces the whole pair and
renders `crt: ""`. That is a control plane with no CA certificate, and it validates clean. Always
carry `crt` and `key` together in whichever file sets either. Typed documents (`kind:`) merge by
kind + `name`, so partial overrides there are safe.

`cluster.yaml.j2` defines the installer image **once**, in its `UnattendedInstallConfig`, as
`factory.talos.dev/installer/{{ ENV.SCHEMATIC }}:<version>`. `render-config` derives the schematic
type from the node name, resolves it against the Image Factory, and injects the ID. The mapping
lives in `talos/mod.just` § `schematic-type`:

| Node name pattern | Schematic      |
| ----------------- | -------------- |
| `*-cp-*`          | `controlplane` |
| `*-gpu-*`         | `gpu`          |
| `ymir`            | `metal`        |
| anything else     | `worker`       |

### `metal` and `controlplane` resolve to the SAME factory ID

`talos/schematics/metal.yaml` and `talos/schematics/controlplane.yaml` are byte-for-byte identical
in content today. They have the same seven extensions and the same kernel args, so the Image Factory
returns one ID for both. These are the live node annotations (`extensions.talos.dev/schematic`):

| Nodes                           | Schematic ID        | Source file                        |
| ------------------------------- | ------------------- | ---------------------------------- |
| `talos-cp-01/02/03`, **`ymir`** | `1ec0c55058196a04…` | `controlplane.yaml` ≡ `metal.yaml` |
| `talos-w-01`, `talos-w-02`      | `a67271c479dead6a…` | `worker.yaml`                      |
| `talos-gpu-01`                  | `5bfc5ba67508c0c6…` | `gpu.yaml`                         |

Never copy an ID out of this table into a manifest. Resolve it with `just talos schematic-id <type>`,
which POSTs the schematic file to the Image Factory. The table explains the collision between ymir
and the control planes. It is not a source of truth.

Two consequences follow, and neither is obvious:

- You cannot tell `ymir` from a control plane by its annotation. Do not use the schematic ID that a
  node reports to infer which schematic _file_ the node tracks. Use `just talos schematic-type <node>`,
  which is the only authority.
- A change to `controlplane.yaml` alone silently changes `ymir` too, and the reverse is also true.
  Both files still hash to one ID until their contents diverge. When one file gains an extension
  that the other lacks, the IDs split and `ymir` starts to track a distinct image. That is intended.
  Do not be surprised when a "control-plane-only" schematic edit reboots the bare-metal worker as
  well.

`metal` is `worker` **minus** `siderolabs/qemu-guest-agent`. On bare metal, that service can never
come up. Talos blocks its boot sequence while it waits for the service, until the phase times out
and the node reboots, roughly every 70 minutes. Bare-metal workers must get `metal`, never `worker`.
Node files carry only the disk selector and the wipe flag. Never hardcode a schematic hash in a node
file. That pattern let `schematics/controlplane.yaml` silently diverge from what the CP nodes
actually ran.

## Extension Changes

Extensions require a new schematic ID and a node reboot. The render computes the ID now, so there is
nothing to update by hand:

1. Edit the schematic in `talos/schematics/<controlplane|worker|gpu|metal>.yaml`. There are **four**
   files, not three. `metal.yaml` is the one that people usually forget.
2. Run `just talos apply-node <node> --mode=reboot`.

To see the image that a node will get without applying, run
`just talos render-config <node> | yq 'select(.kind == "UnattendedInstallConfig") | .installer.image'`.

A schematic change at the same Talos version leaves a boot-order trap. Talos writes the new UKI as
`Talos-<version>~N.efi` beside the original `Talos-<version>.efi` (`sdboot.go:generateNextUKIName()`).
The `strverscmp_improved` function of systemd-boot treats `~` as an rpm-style **pre-release** marker,
so `~N` sorts **below** the plain name. The sort is descending, so the stale original is
`entries[0]`. Our `loader.conf` carries only `timeout 10` and no `default`, so a correct boot depends
entirely on the `LoaderEntryDefault` NVRAM variable. Whenever that variable fails to resolve, sd-boot
falls through to the stale image. The own naming of Talos makes its newest image look older than the
image that it replaced.

Symptom when the node lands on the stale image: the node booted without the `drbd` extension, so
every miroir PVC on it hangs in Init (`diskless leg not realized`; agent log `Module drbd not found in
directory /lib/modules/…-talos`).

A Talos version upgrade clears the trap on its own. It writes a plain-named UKI for the new version
and keeps only that UKI and the previous version, so no `~N` pair survives. The bare-metal nodes
carry no pair after the v1.14.1 and v1.14.2 upgrades, with nothing moved by hand
([#2763](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2763)).
The team had fixed the three Proxmox VMs earlier. On each ESP, it moved the stale plain UKI out of
the sd-boot scan path to `/Talos-v1.14.0.efi.bak`. The trap returns after any same-version schematic
change. After the next reboot of a node that had a schematic change, check the schematic table.

Nothing else reports the trap. The `installer.image` of the machine config stays correct,
`unattendedinstallstatuses` says `phase: installed`, tuppr says Completed (it keys on version, not on
schematic), and the node is `Ready`. Before **and after** you reboot a node for any reason, compare
what it runs against what it must run:

```bash
kubectl get nodes -o json | jq -r '.items[].metadata | "\(.name) \(.annotations["extensions.talos.dev/schematic"][0:12]) drbd=\(.labels["extensions.talos.dev/drbd"] // "-")"'
just talos schematic-id worker          # or controlplane / gpu / metal
talosctl -n <ip> get bootedentries      # which ESP entry actually booted
```

To fix a mismatch, run a same-version `talosctl -n <ip> upgrade -i "$(just talos machine-image <node>)" -m powercycle`.
Only `upgrade` writes an image to disk. `apply-node --mode=reboot` changes the configuration and
reboots, but it does not reinstall. Run `talosctl` against the node **IP**. The short names resolve
only through LAN DNS (public DNS has no record for them). A non-interactive `just` call does not
apply `TALOSCONFIG` from `.mise/config.toml`, so export it in any script. That is why
`just talos upgrade-node` fails from a script with "failed to determine endpoints".

When you diagnose this, read the boot variables directly. They persist correctly, so you can trust
the values:

```bash
G=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
talosctl -n <ip> read /sys/firmware/efi/efivars/LoaderEntryDefault-$G | tail -c +5 | iconv -f UTF-16LE
talosctl -n <ip> read /sys/firmware/efi/efivars/LoaderEntries-$G      | tail -c +5 | iconv -f UTF-16LE
```

The ESP itself is `/dev/vda1`, and Talos does **not** keep it mounted at runtime. On a VM, you can
inspect it from `pantheon` while the guest runs. Mount it `ro`, and write to it only with the guest
stopped:

```bash
mount -o ro /dev/zvol/vmpool/vm-<vmid>-disk-0-part1 /mnt/esp && ls -la /mnt/esp/EFI/Linux/
```

The team has not established why `LoaderEntryDefault` fails to resolve on some nodes and not on
others. Upstream `siderolabs/talos#14146` is the closest match.

## Config Format (Talos 1.14 multi-document)

The templates use the 1.14 typed-document layout. Everything that is still in v1alpha1 is there for
a concrete reason. The team audited it against the full 1.14 document catalogue on 2026-08-03. Do
not "finish" the migration without a re-check against the 1.14 stable reference:

| Stays in v1alpha1                                    | Why                                                                                                                                                                                                                |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `machine.token`, `machine.ca`, `machine.type`        | no document equivalent exists — only the _Kubernetes_ CAs got documents, not the machine CA                                                                                                                        |
| `machine.features.diskQuotaSupport`                  | **no document exists.** Upstream's `VolumeConfig` reference states outright: "project quota support is configured via machine features". Not an oversight — do not go looking for a `VolumeConfig` field for this. |
| `cluster.etcd`                                       | **no etcd document exists at all** in 1.14 — there is no `etcd/` group in the config reference. `advertisedSubnets` and `extraArgs` have nowhere else to live.                                                     |
| PKI (`cluster.ca`, `aggregatorCA`, `serviceAccount`) | the new CA documents parse PEM; the 1Password items hold base64-DER as v1alpha1 expects                                                                                                                            |
| `cluster.clusterName`, `cluster.controlPlane`        | `KubeClusterConfig` — see the DO-NOT-MIGRATE warning below; this one caused an outage                                                                                                                              |

Discovery is on. `DiscoveryServiceConfig` (endpoint `discovery.talos.dev`) and
`DiscoveryIdentityConfig` moved `cluster.id` and `secret` out of v1alpha1, and they register every
node with the public discovery service. That is what populates `talosctl -n <ip> get members` (all
seven nodes). It also lets workers find all three control planes, so they do not lean on the
endpoint alone. The Kubernetes registry has no document at all.

`machine.install` is `UnattendedInstallConfig`. The controller "mirrors the legacy .machine.install
install behavior", but it short-circuits on `Machine().Installed()`. So the document is inert on a
provisioned node. It only fires against a machine that booted from the ISO in maintenance mode.
Legacy `diskSelector.model` globs and bare `disk:` paths became CEL
(`disk.model == "..." && disk.transport == "sata"`, `disk.dev_path == "/dev/vda"`). § tuppr rebuilds
explains the image path prefix.

The templates are kept comment-free. Every "why" for them is in this section. If a line in
`talos/*.j2` looks redundant or wrong, it is almost certainly listed below. Check here before you
delete it.

These cost real downtime when done wrong:

- Never migrate `.cluster.controlPlane` to `KubeClusterConfig` on 1.14.0-beta.1. Removing it leaves
  the field nil, and the v1alpha1→k8s bridge still calls `(*ClusterConfig).Endpoint()` unguarded
  from `K8sServiceAccountConfig()` (`v1alpha1_k8s_bridge.go:331` → `v1alpha1_clusterconfig.go:66`).
  That panics `secrets.RootKubernetesController`, which stops rendering the control plane static
  pods. Every CP comes back from a reboot with no kube-apiserver. This took the whole API down on
  2026-08-03. The node stays Ready, so the fault only bites on reboot. Verify with
  `talosctl get staticpods`.
    - Consequence: `cluster.yaml.j2` sets the worker endpoint and `controlplane.yaml.j2` overrides
      it, so `.cluster.controlPlane` is never absent from a rendered config.
- Disabled components still need an explicit `image:`. `images.List()` of 1.14.0-beta.1 calls
  `mustParseTag` on every component unconditionally. So `KubeProxyConfig` and `KubeCoreDNSConfig`
  with `enabled: false` and no `image:` yield `""` and panic-loop
  `k8s.ControlPlaneBootstrapManifestsController`. That also stalls the manifests that it renders
  unconditionally (CSR approve/renew RBAC, kubelet bootstrap token, kube-config-in-cluster,
  `system:talos-nodes`, the `serviceaccounts.talos.dev` CRD). The values are the own defaults of
  Talos, so nothing is pulled. The components stay disabled (kube-proxy → Cilium, CoreDNS → our own
  `kube-system/coredns` HelmRelease). A Ready cluster hides this fault. Check `talosctl dmesg`.
- `nodeIP` must be in `KubeNodeConfig`, never in `machine.kubelet.nodeIP`. If you set both, it
  errors.
- If you use `KubeAPIServerConfig`, then `KubeAuthorizerConfig` (Node + RBAC) is **mandatory**.
  Without it, kube-apiserver exits with "authorizers: Required value: at least one authorization
  mode must be defined".
- It also makes `KubeAuthenticationConfig` mandatory. Otherwise Talos writes an empty
  authentication-config.yaml, and the apiserver dies on "Object 'Kind' is missing".
- `KubeNodeConfig.taints: {}` (an empty **map**; a list fails to decode) replaces
  `.cluster.allowSchedulingOnControlPlanes: true`. 1.14 lists the controlplane NoSchedule taint
  explicitly instead of defaulting it, and this cluster runs workloads on the CPs.
- The `KubeEtcdEncryptionConfig` secretbox key must stay named `key2`. The name is part of the
  ciphertext prefix of every encrypted secret. If you rename it, existing secrets become
  undecryptable.
- The absence of a `KubeFlannelCNIConfig` document is the new `cluster.network.cni.name: none`.

Quieter ones:

- There is no `TimeSyncConfig` document, on purpose. Talos always emits a `default` layer time
  server (`constants.DefaultNTPServer` = `time.cloudflare.com`) with `useNTS: true`, and `useNTS`
  only defaults to true when no NTP config is provided at all. If you write an explicit
  `TimeSyncConfig` without `useNTS: true`, it silently _disables_ NTS. The UCG-Max at 10.10.99.1
  does not run an NTP daemon (UDP/123 returns connection refused) and does not send DHCP option 42.
  So it was only ever a dead first entry. NTS also requires hostnames, not IPs, so it could not have
  stayed anyway. Verify with `talosctl get timeserverspecs --namespace network-config` (it shows the
  layers), and look for "established NTS session" in `dmesg`. Layer precedence: default → cmdline →
  platform → operator (DHCP) → configuration.

- You must state `SecurityProfileConfig.workloadIsolation: true` explicitly. 1.14 defaults it on for
  new clusters only. Upgraded clusters (this one) keep shared namespaces until the document exists.
  Applying it restarts CRI + kubelet + all pods, with no reboot. The documented casualty is the
  in-tree iSCSI volume plugin. We use miroir (DRBD) and in-tree NFS, and neither needs a host daemon.
- `KubeTalosAPIAccessConfig` has no `enabled` field. The presence of the document turns it on.
- `disableManifestsDirectory` is deliberately absent. v1alpha1 marks it "locked to true in
  multi-doc config", so it is both unnecessary and impossible to set. It was the last thing that
  pinned the kubelet block to v1alpha1. `extraConfig` is spelled `config` on `KubeletConfig`.
- `machine.features.rbac` and `apidCheckExtKeyUsage` no longer exist in the 1.14 v1alpha1 schema.

## 1.14 Documents Considered and NOT Adopted

The team audited these against the full 1.14 catalogue on 2026-08-03. They are deliberate omissions,
not gaps. Re-reading this list is cheaper than rediscovering why each was skipped:

| Document                                           | Why not                                                                                                                |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `TimeSyncConfig`                                   | writing it disables NTS — see the note above                                                                           |
| `KubeClusterConfig`                                | nil-deref outage on beta.1                                                                                             |
| `OOMConfig`                                        | 1.14's userspace OOM handler, driven by CEL trigger/ranking expressions. Not yet evaluated.                            |
| `KmsgLogConfig` / `EventSinkConfig`                | could ship kernel logs and Talos events to VictoriaLogs over tcp/udp. Genuinely attractive here, just not wired up yet |
| `KubeSpanConfig`                                   | single site, no mesh needed                                                                                            |
| `RegistryMirrorConfig` / `ImageCacheConfig`        | no pull-rate or bandwidth problem to solve                                                                             |
| `SwapVolumeConfig` / `ZswapConfig`                 | no swap on these nodes by design                                                                                       |
| `UserVolumeConfig`                                 | no local-path storage; everything is miroir or NFS                                                                     |
| `NetworkRuleConfig` / `NetworkDefaultActionConfig` | host firewall — not attempted; would need care not to lock out the API                                                 |

## kata-containers — provisioned but unused

All four schematics ship `siderolabs/kata-containers` (3.32.0 on the nodes), and a `kata-qemu`
RuntimeClass exists in the cluster. But **no pod uses it**, and nothing in `talos/` wires a
containerd runtime handler for it, because the extension supplies its own. This is a follow-on to
the `workloadIsolation` work, and it is parked
([#2761](https://git.dcunha.io/Exikle/Artemis-Cluster/issues/2761)). Treat the extension as
deliberate, not as a leftover. If you remove it from a schematic, that is a schematic change that
requires reboots, and the tuppr guard assumes that new schematics are supersets of the running one.

To opt a workload in, set `runtimeClassName: kata-qemu`. Each such pod runs in its own lightweight
VM, so it needs `/dev/kvm`. All seven nodes expose it, the Proxmox workers included through nested
virt. The extension registers the `kata-qemu` containerd runtime handler on every node itself.
`kubernetes/apps/kube-system/kata-containers/` only declares the RuntimeClass and its
`overhead.podFixed`.

## `kube-system/bootstrap-token-*` is Talos-managed — do not delete it

A `bootstrap.kubernetes.io/token` Secret in `kube-system` that never expires is exactly what Talos
renders. It is dated cluster-init day, it has `usage-bootstrap-authentication: "true"` and
`auth-extra-groups: system:bootstrappers:nodes`, and it has **no `expiration` field**. It is not a
stale credential.

Talos builds it from `cluster.token` in the machine config (`op://infrastructure/talos/CLUSTER_TOKEN`,
`<id>.<secret>`). The id becomes the Secret name suffix and `token-id`, and the secret becomes
`token-secret`. The template is `k8stemplates/kubelet.go` in siderolabs/talos, and it carries no
`expiration` key at all, so the token is permanent by design. Kubelet TLS bootstrap uses it when a
node joins or re-joins. If you delete it, node join breaks until Talos re-renders it. To rotate it,
you rotate `cluster.token` across every node. Do not edit the Secret.

No RoleBinding points at it, because the bootstrap authenticator of the apiserver consumes it
directly. The absence of RBAC is not evidence that a bootstrap token is unused.

## Automated Upgrades — owned by tuppr

`tuppr` runs in the `system-upgrade` namespace and owns both Talos and Kubernetes upgrades. Upgrades
are declarative. Edit the version in
`kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (or `kubernetesupgrade.yaml`) and
merge, and tuppr rolls the cluster. Do not upgrade a node by hand while tuppr is healthy.

Configuration (`kubernetes/apps/system-upgrade/tuppr/upgrades/`):

| Setting                     | Value                                                                          | Why                                                                                                               |
| --------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| `TalosUpgrade.version`      | read from the CR, not from here                                                | Renovate-tracked via `custom.talos-factory`, automerge OFF                                                        |
| `policy.rebootMode`         | `powercycle`                                                                   |                                                                                                                   |
| `policy.timeout`            | `45m`                                                                          | the 30m default was too tight: factory.talos.dev bakes installer images on first request, which stalls a pre-pull |
| `drain.enabled`             | `true`                                                                         | seven nodes, so there **is** somewhere to drain to (Frostlink has not)                                            |
| Talos health gates          | Node `Ready`, kopiur `Snapshot` not Pending/Running, `MiroirNodeGroup` healthy | never roll the next node onto degraded miroir storage                                                             |
| `KubernetesUpgrade.version` | read from the CR, not from here                                                |                                                                                                                   |
| K8s health gates            | kopiur `Snapshot` idle, `MiroirNodeGroup` healthy                              | stricter than the Talos gate — a K8s upgrade has no reboot to excuse a WARN                                       |

### tuppr rebuilds from the node's RECORDED schematic

tuppr rewrites `.machine.install.image` to `factory.talos.dev/installer/<schematic>:<version>`. It
uses the schematic that the **node reports at runtime**, not the schematic in `talos/schematics/`.
So extensions survive an upgrade without any repo change. It also means that a **stale recorded
schematic silently reinstalls an extension that you removed from git**. Removing an extension takes
two steps. First, edit the schematic file. Then run `just talos apply-node <node> --mode=reboot`, so
that the node re-records the new ID _before_ the next tuppr run. If you edit the schematic file
alone, nothing changes in what tuppr installs.

The image path stays `installer/` instead of the `metal-installer/` of upstream, because the tuppr
`factory-url` annotation pins the same prefix. **Both must move together.** (The tuppr of Frostlink
uses `metal-installer`. The two clusters are deliberately not aligned here.)

You need both tuppr annotations on `KubeNodeConfig` to override the schematic guard.
`tuppr.home-operations.com/schematic` is read only inside the `factory-url` branch of
`buildTalosUpgradeImage`, so it is a no-op alone. This is safe only because each new schematic here
is a superset of the running one. Re-check before a schematic **removes** an extension.

tuppr triggers on `currentVersion != targetVersion`. It is **not** a "newer than" check, and there
is no downgrade guard. Never bump a version out of band while Flux still serves the old value from
git. The next reconcile reverts the CR, and tuppr downgrades the cluster.

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

The cluster has seven nodes, not six. `ymir` is a bare-metal worker (`talos/nodes/ymir.yaml.j2`),
and it is the only node on the `metal` schematic. Anything that counts nodes, such as a tuppr
blast-radius argument or a drain plan, must count seven. Node files are the ground truth:
`ls talos/nodes/`.
