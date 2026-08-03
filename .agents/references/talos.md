# Reference: Talos — Artemis-Cluster

## Config Management

```bash
just talos render-config <node>     # render node config from template
just talos apply-node <node>        # apply config to node (live, no reboot)
```

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
schematic type from the node name (`*-cp-*` → controlplane, `*-gpu-*` → gpu, else worker),
resolves it against the Image Factory, and injects the ID. Node files carry only the disk
selector and wipe flag. Never hardcode a schematic hash in a node file — that pattern let
`schematics/controlplane.yaml` silently diverge from what the CP nodes actually ran.

## Extension Changes

Extensions require a new schematic ID and node reboot. The ID is now computed at render
time, so there is nothing to hand-update:

1. Edit the schematic in `talos/schematics/<controlplane|worker|gpu>.yaml`
2. `just talos apply-node <node> --mode=reboot`

To see the image a node will get without applying:
`just talos render-config <node> | yq 'select(.kind == "UnattendedInstallConfig") | .installer.image'`.

## Config Format (Talos 1.14 multi-document)

The templates are on the 1.14 typed-document layout. Two things deliberately stay on the
deprecated v1alpha1 path, each for a concrete reason — do not "finish" the migration
without re-checking these against the 1.14 stable reference:

| Stays in v1alpha1 | Why                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PKI               | the new CA documents parse PEM; the 1Password items hold base64-DER as v1alpha1 expects                                                                                                                                                                                                                                                                                                                                 |
| cluster identity  | `.cluster.discovery` is unset → zero value → discovery is **off** cluster-wide (`get discoveryconfig` is all-false, `get members` empty, so `resolveMemberNames` is inert). `DiscoveryServiceConfig` is the only thing that populates ServiceEndpoints, so adding it would switch discovery on and register every node with public discovery.talos.dev. Not a refactor. The Kubernetes registry has no document at all. |

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

## Automated Upgrades

`tuppr` runs in the `system-upgrade` namespace and handles automated Kubernetes and Talos version upgrades. Check its plans before manually upgrading nodes.

## Node Reference

| Node           | Role          | Hardware                         | IP         |
| -------------- | ------------- | -------------------------------- | ---------- |
| `talos-cp-01`  | Control plane | Lenovo M710q                     | 10.10.99.x |
| `talos-cp-02`  | Control plane | Lenovo M710q                     | 10.10.99.x |
| `talos-cp-03`  | Control plane | Lenovo M710q                     | 10.10.99.x |
| `talos-w-01`   | Worker        | Proxmox VM (pantheon)            | 10.10.99.x |
| `talos-w-02`   | Worker        | Proxmox VM (pantheon)            | 10.10.99.x |
| `talos-gpu-01` | Worker + GPU  | Proxmox VM, Arc A380 passthrough | 10.10.99.x |
