# Skill: Talos Operations

Node operations for Artemis-Cluster (Talos Linux with render-config / Jinja2 templates).

> Also read `.agents/references/talos.md` for node IPs and config background.

## Config Changes (no reboot)

1. Edit `talos/nodes/<node>.yaml.j2`
2. `just talos render-config <node>`
3. `just talos apply-node <node>`

## Config Changes (with reboot)

```bash
just talos render-config <node>
just talos apply-node <node> --mode=reboot
```

Drain the node first if it runs stateful workloads:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# apply + reboot
kubectl uncordon <node>
```

## Extension Changes

Extensions need a new schematic ID and reboot:

1. Edit `talos/schematics/<node>.yaml`
2. `just talos gen-schematic-id <schematic>` — registers with Sidero Image Factory, prints new ID
3. Update `talos/nodes/<node>.yaml.j2` with the new schematic ID
4. `just talos apply-node <node> --mode=reboot`

## NEVER use `talosctl patch machineconfig` with a full config

Full config passed as a patch causes array fields (`machine.files`, `machine.certSANs`) to be **duplicated** in the merge, which can produce a read-only filesystem on next boot. Always use:

- `just talos apply-node <node>` — for full config replacement (render-config output)
- A minimal 6-line delta patch file for targeted changes (e.g., certSANs only)

Minimal certSANs patch example:

```yaml
machine:
    certSANs:
        - <ip-or-hostname>
cluster:
    apiServer:
        certSANs:
            - <ip-or-hostname>
```

Apply: `talosctl apply-config --file patch.yaml -n <node-ip>`

## Node Health

```bash
talosctl health -n <node-ip>
talosctl dmesg -n <node-ip> | tail -30
talosctl version -n <node-ip>
talosctl get machineconfig -n <node-ip> -o yaml
```

## Automated Upgrades (tuppr)

Check `tuppr` plans before manually upgrading — it manages automated Talos + Kubernetes upgrades:

```bash
kubectl get plans -n system-upgrade
kubectl get jobs -n system-upgrade -o wide
```

## Manual Talos Upgrade (single node)

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
talosctl upgrade -n <node-ip> \
  --image factory.talos.dev/installer/<schematic-id>:<version> \
  --wait
kubectl uncordon <node>
```

Get the schematic ID from `talos/schematics/<node>.yaml` after running `just talos gen-schematic-id`.

## Node Reference

| Node           | Role                    | IP         |
| -------------- | ----------------------- | ---------- |
| `talos-cp-01`  | Control plane           | 10.10.99.x |
| `talos-cp-02`  | Control plane           | 10.10.99.x |
| `talos-cp-03`  | Control plane           | 10.10.99.x |
| `talos-w-01`   | Worker                  | 10.10.99.x |
| `talos-w-02`   | Worker                  | 10.10.99.x |
| `talos-gpu-01` | Worker + GPU (Arc A380) | 10.10.99.x |

> Exact IPs: see `.agents/references/talos.md` or `reference_ips.md` in memory.
