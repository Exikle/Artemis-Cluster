# Config Management

Talos machine configs are managed via a **render-config** workflow using MiniJinja templates and `talosctl machineconfig patch`. This replaced the previous `talhelper` approach.

---

## File Layout

```
talos/
├── machineconfig.yaml.j2    # Base machine config template (shared by all nodes)
├── nodes/
│   ├── talos-cp-01.yaml.j2  # Per-node patch + type declaration
│   ├── talos-cp-02.yaml.j2
│   ├── talos-cp-03.yaml.j2
│   ├── talos-w-01.yaml.j2
│   ├── talos-w-02.yaml.j2
│   └── talos-gpu-01.yaml.j2
├── schematics/
│   ├── controlplane.yaml    # Schematic for CP nodes
│   ├── worker.yaml          # Schematic for standard workers
│   └── gpu.yaml             # Schematic for GPU worker
├── talconfig.yaml           # Node inventory/reference (not used for config generation)
└── mod.just                 # Just tasks
```

---

## How It Works

### 1. Template rendering

`machineconfig.yaml.j2` is a MiniJinja template for the base config shared by all nodes. The `IS_CONTROLLER` environment variable controls control-plane-specific blocks (etcd CA keys, API server config, kubernetesTalosAPIAccess, etc.).

Per-node patches (`nodes/<node>.yaml.j2`) declare the `machine.type`, `install.image`, `install.disk`, node labels, and hostname.

### 2. Rendering a config

```bash
just talos render-config talos-cp-01
```

This sets `IS_CONTROLLER` by inspecting the node's type, renders `machineconfig.yaml.j2`, then patches it with `nodes/talos-cp-01.yaml.j2`.

### 3. Applying a config

```bash
just talos apply-node talos-cp-01
```

Pipes `render-config` directly into `talosctl apply-config`. No intermediate files are written to disk.

For initial (insecure) apply during bootstrap:

```bash
just talos apply-node talos-cp-01 --insecure
```

For a change that requires a reboot:

```bash
just talos apply-node talos-w-01 --mode=reboot
```

---

## Schematics

Schematics define the kernel args and system extensions for each node type. They are submitted to [factory.talos.dev](https://factory.talos.dev) to generate a unique schematic ID, which becomes the installer image URL.

| Schematic      | Extensions                                          | Extra kernel args                                            |
| -------------- | --------------------------------------------------- | ------------------------------------------------------------ |
| `controlplane` | i915, intel-ucode, mei, nfsrahead, util-linux-tools | lockdown=integrity, mitigations=off                          |
| `worker`       | + qemu-guest-agent                                  | same as controlplane                                         |
| `gpu`          | + qemu-guest-agent                                  | + intel_iommu=on, iommu=pt, i915.enable_guc=3, pcie_aspm=off |

### Generating a schematic ID

```bash
just talos gen-schematic-id controlplane
# → 4ba058235b9a91962983fdb0a4e04979567495c7dea6dd5ec3f7d1e337f8ee7b
```

### Downloading an image

```bash
just talos download-image v1.12.6 controlplane
```

Downloads a secureboot ISO to `talos/talos-v1.12.6-controlplane.iso`.

### Updating extensions on a node

1. Edit the relevant schematic file in `talos/schematics/`
2. Run `just talos gen-schematic-id <schematic>` to get the new hash
3. Update `machine.install.image` in the node's `.yaml.j2` file
4. Apply and reboot: `just talos apply-node <node> --mode=reboot`

---

## Secrets

All sensitive values in `machineconfig.yaml.j2` use 1Password `op://` references (e.g. `op://kubernetes/talos/MACHINE_TOKEN`). These are resolved at render time by `op` CLI before the config is applied.

No SOPS encryption is used for Talos configs.

---

## talconfig.yaml

`talconfig.yaml` is retained as a human-readable node inventory (IPs, disk selectors, types). It is **not** used for config generation — the `genconfig` task was removed. Treat it as documentation.
