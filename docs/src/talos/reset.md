# Node Reset

Procedures for resetting individual nodes or the entire cluster.

---

## Reset a Single Node

Use `just talos reset-node` — it prompts for confirmation before executing.

```bash
just talos reset-node talos-w-01
```

This runs `talosctl reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --graceful=false`. Only STATE and EPHEMERAL partitions are wiped; the OS installation remains. The node reboots into a clean state and can be re-configured with `apply-node`.

> For worker VMs that hang during reboot (kernel RBD stall), hard-reset via Proxmox: `qm reset <vmid>`

---

## Full Cluster Reset

Wipes all nodes completely (OS disk included). Use this only when rebuilding from scratch.

### Step 1: Reset all nodes

```bash
# Control planes
talosctl -n 10.10.99.101 reset --graceful=false --reboot
talosctl -n 10.10.99.102 reset --graceful=false --reboot
talosctl -n 10.10.99.103 reset --graceful=false --reboot

# Workers
talosctl -n 10.10.99.201 reset --graceful=false --reboot
talosctl -n 10.10.99.202 reset --graceful=false --reboot
talosctl -n 10.10.99.203 reset --graceful=false --reboot
```

After reset, each node's disk is completely wiped. Nodes will reboot but cannot boot from disk.

### Step 2: Boot nodes from Talos USB/ISO

Each node must boot from a Talos installation ISO to get back to maintenance mode. Download the correct image for each schematic:

```bash
just talos download-image v1.12.6 controlplane   # for CPs
just talos download-image v1.12.6 worker         # for workers
just talos download-image v1.12.6 gpu            # for talos-gpu-01
```

Flash to USB and boot each node. For worker VMs on Proxmox, attach the ISO in the VM's CD drive and set boot order to CD first.

### Step 3: Re-bootstrap

Once all nodes are in maintenance mode, run the full bootstrap:

```bash
just
```

See [Bootstrap](bootstrap.md) for full stage details.

---

## Rebooting a Node

```bash
just talos reboot-node talos-cp-01
```

Uses `powercycle` mode (graceful shutdown + power cycle) with a confirmation prompt.

---

## Shutting Down a Node

```bash
just talos shutdown-node talos-cp-01
```

---

## Health Check

```bash
just talos check-cluster-health

# Or directly
talosctl health --nodes 10.10.99.101
```

---

## Dashboard

```bash
just talos open-dashboard
```

Opens an interactive Talos dashboard for the first control plane node.
