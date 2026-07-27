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

## Talos 1.14 Migration

`talos/machineconfig.v1.14.yaml.j2` holds the 1.14 multi-document translation of the live
config. It is staged, not active — 1.14 is at beta as of 2026-07-27 and talosctl 1.13.x
does not recognise the new kinds. The file's header comment carries the migration
checklist and the unresolved `TODO(1.14)` items (notably: no documented home for
`kubelet.extraMounts`, which the openebs hostpath bind mount depends on).

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
