# Reference: Talos — Artemis-Cluster

## Config Management

```bash
just talos render-config <node>     # render node config from template
just talos apply-node <node>        # apply config to node (live, no reboot)
```

Config lives in `talos/nodes/<node>.yaml.j2` (Jinja2 templates, rendered by `render-config`).

## Extension Changes

Extensions require a new schematic ID and node reboot:

1. Edit the schematic in `talos/schematics/<node>.yaml`
2. `just talos gen-schematic-id <schematic>` — generates new ID via Sidero Image Factory
3. Update `talos/nodes/<node>.yaml.j2` with the new schematic ID
4. `just talos apply-node <node> --mode=reboot`

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
