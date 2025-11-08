# Talos Cluster Reset and Rebuild Guide

## Overview
This guide details the complete process to destroy and rebuild the Artemis Talos cluster. The cluster consists of:
- **Control Plane Nodes**: 10.10.99.101, 10.10.99.102, 10.10.99.103
- **Worker Nodes**: 10.10.99.201, 10.10.99.202

## Prerequisites
- USB drives with Talos OS ISO (one per node or reusable)
- Access to physical nodes and their BIOS/boot menus
- Backup of any critical data or configurations

## Phase 1: Reset All Nodes

### Step 1: Reset Control Plane Nodes

Run the following commands to completely wipe each control plane node:

```bash
# Control Plane 1
talosctl -n 10.10.99.101 reset --graceful=false --reboot

# Control Plane 2
talosctl -n 10.10.99.102 reset --graceful=false --reboot

# Control Plane 3
talosctl -n 10.10.99.103 reset --graceful=false --reboot
```

### Step 2: Reset Worker Nodes

```bash
# Worker 1
talosctl -n 10.10.99.201 reset --graceful=false --reboot

# Worker 2
talosctl -n 10.10.99.202 reset --graceful=false --reboot
```

**Important Notes:**
- The `--graceful=false` flag skips graceful shutdown since we're destroying the entire cluster
- The `--reboot` flag causes nodes to reboot after wiping
- This command wipes the **entire disk**, including the Talos OS installation
- Nodes will reboot but will not be able to boot from disk after reset

## Phase 2: Reinstall Talos OS from USB

After reset, each node's disk is completely wiped and requires a fresh Talos installation.

### Step 1: Prepare Talos USB Installation Media

Download the latest Talos OS ISO:
```bash
# Check for latest version at https://github.com/siderolabs/talos/releases
curl -LO https://github.com/siderolabs/talos/releases/download/v1.x.x/metal-amd64.iso
```

Create bootable USB drives using Rufus, Etcher, or dd:
```bash
# Linux/macOS example
sudo dd if=metal-amd64.iso of=/dev/sdX bs=4M status=progress && sync
```

### Step 2: Boot Each Node from USB

For each node (do this sequentially or in parallel if you have multiple USB drives):

1. Insert the Talos USB drive into the node
2. Power on the node (or it may already be rebooting from the reset command)
3. Access the boot menu (typically F10, F12, ESC, or DEL key)
4. Select the USB drive as the boot device
5. Wait for Talos OS to boot from the USB

**The node will now be running Talos in maintenance mode from the USB drive.**

### Step 3: Install Talos to Disk

Once booted from USB, you need to install Talos to the node's disk. This is typically done during the config apply process, but if you need to manually install:

```bash
# The bootstrap process will handle installation when you apply configs
# Talos will automatically install to disk when applying the machine config
```

**Remove the USB drive after the config is applied and before the first reboot to ensure the node boots from the installed disk.**

## Phase 3: Bootstrap the Cluster

Once all nodes have Talos installed from USB and are running, proceed with the bootstrap:

### Step 1: Apply Configuration to All Nodes

```bash
task talos:bootstrap-cluster
```

This will decrypt and apply configurations to all nodes:
- Control Plane 1 (10.10.99.101)
- Control Plane 2 (10.10.99.102)
- Control Plane 3 (10.10.99.103)
- Workers will need their configs applied separately if not included

### Step 2: Configure Talos Endpoints

```bash
task talos:bootstrap-endpoints
```

This sets up the control plane endpoints in your talosconfig.

### Step 3: Bootstrap Kubernetes

```bash
task talos:bootstrap-startcluster
```

This initializes the Kubernetes cluster on the first control plane node.

### Step 4: Install Core Components

```bash
task helm:bootstrap
task talos:bootstrap-applyhelm
```

This installs Cilium, CoreDNS, and other essential components.

### Alternative: Run Complete Bootstrap

You can run all bootstrap steps at once:

```bash
task talos:bootstrap
```

## Phase 4: Verify Cluster

After bootstrap is complete, verify the cluster is healthy:

```bash
# Check cluster health
talosctl -n 10.10.99.101 health

# Check node status
kubectl get nodes

# Check system pods
kubectl get pods -A

# Verify etcd members
talosctl -n 10.10.99.101 etcd members
```

## Troubleshooting

### Node Won't Boot After Reset
- The disk has been completely wiped
- Boot from USB with Talos ISO
- Reapply the machine configuration

### Node Boots to USB Instead of Disk
- Remove the USB drive after config application
- Reboot the node
- Ensure BIOS boot order prioritizes the internal disk

### Machine Config Application Fails
- Ensure the node is accessible via network
- Verify USB boot was successful
- Check that you're using the correct node IP address
- Use `--insecure` flag if needed during initial config application

## Notes

- The reset process is **destructive** and **irreversible**
- All data on the nodes will be permanently deleted
- Configurations are stored in the Git repository and will be reapplied
- The USB installation step is **required** after reset because the disk is completely wiped
- Each node must boot from USB at least once before it can have Talos installed to disk

## References

- Talos Documentation: https://www.talos.dev/
- Artemis Cluster Repository: https://github.com/Exikle/Artemis-Cluster
