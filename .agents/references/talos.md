# Reference: Talos — Artemis-Cluster

## Config Management

```bash
just talos render-config <node>     # render node config from template
just talos apply-node <node>        # apply config to node (live, no reboot)
```

Shared settings live in `talos/machineconfig.yaml.j2`; per-node overrides in
`talos/nodes/<node>.yaml.j2` (Jinja2 templates, rendered by `render-config`).

The installer image is defined **once**, in the base config, as
`factory.talos.dev/installer/{{ ENV.SCHEMATIC }}:<version>`. `render-config` derives the
schematic type from the node name (`*-cp-*` → controlplane, `*-gpu-*` → gpu, else worker),
resolves it against the Image Factory, and injects the ID. Node files carry only the disk
target and wipe flag. Never hardcode a schematic hash in a node file — that pattern let
`schematics/controlplane.yaml` silently diverge from what the CP nodes actually ran.

## Extension Changes

Extensions require a new schematic ID and node reboot. The ID is now computed at render
time, so there is nothing to hand-update:

1. Edit the schematic in `talos/schematics/<controlplane|worker|gpu>.yaml`
2. `just talos apply-node <node> --mode=reboot`

To see the image a node will get without applying: `just talos render-config <node> | yq '.machine.install.image'`.

## Config Format (Talos 1.14 multi-document)

`machineconfig.yaml.j2` is on the 1.14 typed-document layout. Three things deliberately
stay on the deprecated v1alpha1 path, each for a concrete reason — do not "finish" the
migration without re-checking these against the 1.14 stable reference:

| Stays in v1alpha1                 | Why                                                                                                                                                                                                                                                                                                                                       |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| the whole `machine.kubelet` block | `disableManifestsDirectory` is rejected by both `KubeletConfig` and `KubeNodeConfig`, and `KubeletConfig` cannot coexist with `machine.kubelet`. This is now the _only_ blocker — the `extraMounts` openebs bind mount was removed with openebs (2026-07-27). Dropping `disableManifestsDirectory` would free the whole block to migrate. |
| PKI + cluster identity            | the new CA documents parse PEM; the 1Password items hold base64-DER as v1alpha1 expects                                                                                                                                                                                                                                                   |
| `machine.install`                 | keeps `just talos machine-image` and the tuppr factory-url flow on one path                                                                                                                                                                                                                                                               |

Gotchas that cost real downtime when getting this wrong:

- `nodeIP` must be in `KubeNodeConfig`, never `machine.kubelet.nodeIP` — setting both errors.
- Using `KubeAPIServerConfig` makes `KubeAuthorizerConfig` (Node + RBAC) **mandatory**; without
  them kube-apiserver exits with "authorizers: Required value: at least one authorization mode
  must be defined".
- It also makes `KubeAuthenticationConfig` mandatory — Talos writes an empty
  authentication-config.yaml otherwise and the apiserver dies on "Object 'Kind' is missing".
- `KubeNodeConfig.taints: {}` (empty **map**, a list fails to decode) replaces
  `.cluster.allowSchedulingOnControlPlanes: true`.
- `KubeEtcdEncryptionConfig` secretbox key must stay named `key2` — the name is part of every
  encrypted secret's ciphertext prefix.
- Absence of a `KubeFlannelCNIConfig` document is the new `cluster.network.cni.name: none`.

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
