#!/bin/bash
set -e  # Exit on error

# Cluster Configuration
CONTROL_PLANE_NODES=("10.10.99.101" "10.10.99.102" "10.10.99.103")
WORKER_NODES=("10.10.99.201" "10.10.99.202")
VIP="10.10.99.99"

# Define the upgrade path from 1.7.4
VERSIONS=("v1.7.7" "v1.8.4" "v1.9.3" "v1.10.2" "v1.11.3")

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_skip() {
    echo -e "${BLUE}[SKIP]${NC} $1" >&2
}

# Function to get node version
get_node_version() {
    local node=$1
    local version=$(talosctl -n $node version --short 2>/dev/null | grep "Tag:" | awk '{print $2}' | tr -d '\n' || echo "")
    echo "$version"
}

# Function to compare semantic versions
# Returns 0 if current >= target (skip upgrade)
# Returns 1 if current < target (needs upgrade)
version_compare() {
    local current=$1
    local target=$2

    # Handle empty versions
    if [ -z "$current" ] || [ -z "$target" ]; then
        return 1  # Needs upgrade if we can't determine version
    fi

    # Remove 'v' prefix
    current=${current#v}
    target=${target#v}

    # If versions are identical, skip
    if [ "$current" == "$target" ]; then
        return 0
    fi

    # Split versions into arrays
    IFS='.' read -ra CURR <<< "$current"
    IFS='.' read -ra TARG <<< "$target"

    # Ensure we have 3 components, default to 0 if missing
    for i in 0 1 2; do
        if [ -z "${CURR[$i]}" ]; then
            CURR[$i]=0
        fi
        if [ -z "${TARG[$i]}" ]; then
            TARG[$i]=0
        fi
    done

    # Compare major version
    if [ "${CURR[0]}" -gt "${TARG[0]}" ]; then
        return 0  # Current is newer, skip
    elif [ "${CURR[0]}" -lt "${TARG[0]}" ]; then
        return 1  # Current is older, upgrade needed
    fi

    # Compare minor version
    if [ "${CURR[1]}" -gt "${TARG[1]}" ]; then
        return 0  # Current is newer, skip
    elif [ "${CURR[1]}" -lt "${TARG[1]}" ]; then
        return 1  # Current is older, upgrade needed
    fi

    # Compare patch version
    if [ "${CURR[2]}" -gt "${TARG[2]}" ]; then
        return 0  # Current is newer, skip
    elif [ "${CURR[2]}" -lt "${TARG[2]}" ]; then
        return 1  # Current is older, upgrade needed
    fi

    # Versions are equal
    return 0
}

# Function to upgrade a single node with force flag
upgrade_node() {
    local node=$1
    local version=$2
    local node_type=$3

    # Check current version
    log_info "Checking current version on $node..."
    local current_version=$(get_node_version $node)

    if [ -z "$current_version" ]; then
        log_warn "Could not determine current version for $node, proceeding with upgrade..."
    else
        if version_compare "$current_version" "$version"; then
            log_skip "Node $node is on $current_version (>= $version), skipping upgrade"
            return 0
        else
            log_info "Node $node is on $current_version, needs upgrade to $version"
        fi
    fi

    log_info "Force upgrading $node_type node $node to $version..."

    # Use --force to skip health checks and drain issues
    if ! talosctl upgrade -n $node \
        --image ghcr.io/siderolabs/installer:${version} \
        --preserve \
        --force \
        --wait=false; then
        log_error "Failed to initiate upgrade for $node"
        return 1
    fi

    log_info "Upgrade initiated on $node (non-blocking mode)"
    sleep 10

    # Wait for node to start upgrading
    log_info "Waiting for $node to reboot and upgrade..."
    sleep 120

    # Wait for node to come back online
    log_info "Waiting for $node to be ready..."
    local retries=0
    while [ $retries -lt 40 ]; do
        if talosctl -n $node version &> /dev/null 2>&1; then
            local new_version=$(get_node_version $node)
            if [ -n "$new_version" ]; then
                log_info "$node is responsive, now on version: $new_version"

                # Verify it upgraded correctly
                if version_compare "$new_version" "$version"; then
                    log_info "✓ $node successfully upgraded to $new_version"
                    break
                else
                    log_warn "$node reports version $new_version (expected >= $version)"
                    break
                fi
            else
                log_warn "$node is responsive but version couldn't be determined"
                break
            fi
        fi
        log_warn "Node $node not ready, waiting... (attempt $((retries+1))/40)"
        sleep 30
        retries=$((retries+1))
    done

    if [ $retries -eq 40 ]; then
        log_error "$node failed to come back online"
        return 1
    fi

    return 0
}

# Function to check etcd health (lenient)
check_etcd_health() {
    log_info "Checking etcd health..."
    local retries=0
    while [ $retries -lt 15 ]; do
        if talosctl -n ${CONTROL_PLANE_NODES[0]} service etcd status &> /dev/null 2>&1; then
            log_info "etcd is healthy"
            return 0
        fi
        log_warn "etcd not ready yet, waiting... (attempt $((retries+1))/15)"
        sleep 30
        retries=$((retries+1))
    done
    log_error "etcd health check failed after 15 attempts"
    return 1
}

# Function to check VIP status
check_vip() {
    log_info "Checking VIP status on $VIP..."
    if timeout 10 kubectl --request-timeout=5s --server=https://${VIP}:6443 version &> /dev/null 2>&1; then
        log_info "VIP $VIP is accessible"
    else
        log_warn "VIP $VIP may not be responding (this is OK during CP upgrades)"
    fi
}

# Function to find minimum version across all nodes
get_min_version() {
    local min_version="v999.999.999"

    for node in "${CONTROL_PLANE_NODES[@]}" "${WORKER_NODES[@]}"; do
        local ver=$(get_node_version $node)
        if [ -n "$ver" ]; then
            # Remove 'v' prefix for comparison
            local ver_num=${ver#v}
            local min_num=${min_version#v}

            IFS='.' read -ra VER <<< "$ver_num"
            IFS='.' read -ra MIN <<< "$min_num"

            # Default to 0 if component is missing
            for i in 0 1 2; do
                if [ -z "${VER[$i]}" ]; then VER[$i]=0; fi
                if [ -z "${MIN[$i]}" ]; then MIN[$i]=0; fi
            done

            # Compare versions
            if [ "${VER[0]}" -lt "${MIN[0]}" ] || \
               ([ "${VER[0]}" -eq "${MIN[0]}" ] && [ "${VER[1]}" -lt "${MIN[1]}" ]) || \
               ([ "${VER[0]}" -eq "${MIN[0]}" ] && [ "${VER[1]}" -eq "${MIN[1]}" ] && [ "${VER[2]}" -lt "${MIN[2]}" ]); then
                min_version="$ver"
            fi
        fi
    done

    # If no valid version found, return empty
    if [ "$min_version" == "v999.999.999" ]; then
        echo ""
    else
        echo "$min_version"
    fi
}

# Function to determine which versions need to be applied
get_needed_versions() {
    local min_ver=$(get_min_version)

    if [ -z "$min_ver" ]; then
        # Return all versions if we can't determine
        for version in "${VERSIONS[@]}"; do
            echo "$version"
        done
        return
    fi

    # Only return versions that are higher than min_ver
    for version in "${VERSIONS[@]}"; do
        if ! version_compare "$min_ver" "$version"; then
            echo "$version"
        fi
    done
}

# Main upgrade process
main() {
    log_info "========================================="
    log_info "Talos FORCE Upgrade Script (Smart Resume)"
    log_info "========================================="
    log_info "VIP: $VIP"
    log_info "Control Plane Nodes: ${CONTROL_PLANE_NODES[@]}"
    log_info "Worker Nodes: ${WORKER_NODES[@]}"
    log_info "Full Upgrade Path: ${VERSIONS[@]}"
    log_info "========================================="
    log_warn "Using --force flag to bypass pod draining"
    log_warn "This will forcefully terminate pods!"
    log_info "========================================="

    # Verify current version on all nodes
    log_info "Current versions:"
    for node in "${CONTROL_PLANE_NODES[@]}" "${WORKER_NODES[@]}"; do
        local ver=$(get_node_version $node)
        if [ -n "$ver" ]; then
            log_info "  $node: $ver"
        else
            log_warn "  $node: Unable to determine version"
        fi
    done

    # Determine which versions actually need to be applied
    local min_ver=$(get_min_version)
    if [ -n "$min_ver" ]; then
        log_info "Minimum version across cluster: $min_ver"
    fi

    # Get needed versions as array
    local needed_versions=()
    while IFS= read -r version; do
        if [ -n "$version" ]; then
            needed_versions+=("$version")
        fi
    done < <(get_needed_versions)

    if [ ${#needed_versions[@]} -eq 0 ]; then
        log_info "All nodes are already at or above v1.11.3!"
        log_info "No upgrades needed."
        exit 0
    fi

    log_info "Versions that will be applied: ${needed_versions[@]}"
    echo "" >&2

    read -p "Proceed with FORCE upgrade? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_warn "Upgrade cancelled by user"
        exit 0
    fi

    # Backup etcd before starting
    log_info "Creating etcd backup..."
    BACKUP_FILE="etcd-backup-$(date +%Y%m%d-%H%M%S).db"
    if talosctl -n ${CONTROL_PLANE_NODES[0]} etcd snapshot $BACKUP_FILE 2>/dev/null; then
        log_info "Backup saved to $BACKUP_FILE"
    else
        log_warn "Failed to create etcd backup (cluster may be degraded)"
        read -p "Continue anyway? (yes/no): " continue_confirm
        if [ "$continue_confirm" != "yes" ]; then
            exit 1
        fi
    fi

    # Loop through each needed version
    for version in "${needed_versions[@]}"; do
        log_info "========================================="
        log_info "Target Version: $version"
        log_info "========================================="

        log_info "Starting FORCE upgrade to $version"

        # Upgrade control plane nodes one at a time
        for cp_node in "${CONTROL_PLANE_NODES[@]}"; do
            upgrade_node $cp_node $version "control-plane" || {
                log_error "Failed to upgrade $cp_node, attempting to continue..."
                sleep 60
            }

            # Check etcd health after each CP upgrade
            check_etcd_health || {
                log_warn "etcd health check failed, waiting longer..."
                sleep 60
            }

            # Pause between CP nodes
            log_info "Waiting 60s before next control plane node..."
            sleep 60
        done

        log_info "All control plane nodes processed for $version"
        check_vip

        # Upgrade worker nodes
        for worker_node in "${WORKER_NODES[@]}"; do
            upgrade_node $worker_node $version "worker" || {
                log_error "Failed to upgrade $worker_node, attempting to continue..."
                sleep 60
            }
        done

        log_info "All worker nodes processed for $version"

        log_info "========================================="
        log_info "Version $version upgrade complete"
        log_info "========================================="

        # Verify all nodes made it to target version
        log_info "Verifying all nodes are on >= $version..."
        for node in "${CONTROL_PLANE_NODES[@]}" "${WORKER_NODES[@]}"; do
            local ver=$(get_node_version $node)
            if [ -n "$ver" ]; then
                if version_compare "$ver" "$version"; then
                    log_info "  ✓ $node: $ver"
                else
                    log_warn "  ✗ $node: $ver (expected >= $version)"
                fi
            else
                log_warn "  ? $node: Unable to determine version"
            fi
        done

        # Give cluster time to stabilize before next version
        log_info "Waiting 90s for cluster to stabilize before next version..."
        sleep 90
    done

    # Final verification
    log_info "========================================="
    log_info "Upgrade Complete!"
    log_info "========================================="
    log_info "Final versions on all nodes:"

    for node in "${CONTROL_PLANE_NODES[@]}" "${WORKER_NODES[@]}"; do
        local ver=$(get_node_version $node)
        if [ -n "$ver" ]; then
            log_info "  $node: $ver"
        else
            log_warn "  $node: Unable to determine version"
        fi
    done

    check_vip

    log_info "Checking cluster status..."
    kubectl get nodes -o wide 2>/dev/null || log_warn "Could not get node status"
    kubectl get pods -n kube-system 2>/dev/null || log_warn "Could not get pod status"

    log_info "All nodes should now be on v1.11.3!"
    log_warn "Check your cluster status and workloads"
}

# Run main function
main
