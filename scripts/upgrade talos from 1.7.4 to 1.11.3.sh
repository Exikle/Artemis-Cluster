#!/bin/bash

# Define your nodes
CONTROL_PLANE_NODES=("10.10.99.101" "10.10.99.102" "10.10.99.103")
WORKER_NODES=("10.10.99.201" "10.10.99.202")

# Define the upgrade path - USING SECUREBOOT IMAGES
VERSIONS=("v1.7.7" "v1.8.4" "v1.9.3" "v1.10.2" "v1.11.3")

# Function to upgrade a single node
upgrade_node() {
    local node=$1
    local version=$2
    echo "Upgrading node $node to $version..."
    # CRITICAL: Use installer-secureboot image
    talosctl upgrade -n $node --image ghcr.io/siderolabs/installer-secureboot:$version

    # Wait for node to complete upgrade
    sleep 60

    # Check cluster health
    echo "Checking cluster health..."
    talosctl health --wait-timeout 10m
}

# Backup etcd before starting
echo "Creating etcd backup..."
talosctl -n ${CONTROL_PLANE_NODES[0]} etcd snapshot etcd-backup-$(date +%Y%m%d-%H%M%S).db

# Loop through each version
for version in "${VERSIONS[@]}"; do
    echo "========================================="
    echo "Starting upgrade to $version (SecureBoot)"
    echo "========================================="

    # Upgrade control plane nodes one at a time
    for cp_node in "${CONTROL_PLANE_NODES[@]}"; do
        upgrade_node $cp_node $version
    done

    # Upgrade worker nodes
    for worker_node in "${WORKER_NODES[@]}"; do
        upgrade_node $worker_node $version
    done

    echo "All nodes upgraded to $version"
    echo ""
done

echo "Upgrade complete! All nodes are now on v1.11.3"
