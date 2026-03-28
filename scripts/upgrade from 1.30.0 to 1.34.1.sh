#!/bin/bash
set -e  # Exit on error

# Cluster Configuration
CONTROL_PLANE_NODE="10.10.99.101"  # Primary control plane for commands
VIP="10.10.99.99"

# Kubernetes upgrade path (can only skip 1 minor version at a time)
# From 1.30.0, we need to go: 1.30.x -> 1.31.x -> 1.32.x -> 1.33.x -> 1.34.x
K8S_VERSIONS=("1.31.4" "1.32.2" "1.33.3" "1.34.1")

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_skip() {
    echo -e "${BLUE}[SKIP]${NC} $1"
}

# Function to get current Kubernetes version
get_k8s_version() {
    local version=""

    # Try method 1: kubectl version
    version=$(kubectl version -o json 2>/dev/null | grep -o '"gitVersion":"v[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/v//' || echo "")

    # Try method 2: kubectl get nodes
    if [ -z "$version" ]; then
        version=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null | sed 's/v//' || echo "")
    fi

    # Try method 3: talosctl
    if [ -z "$version" ]; then
        version=$(talosctl -n $CONTROL_PLANE_NODE get members -o json 2>/dev/null | grep -o '"kubernetes":"v[0-9.]*"' | head -1 | cut -d'"' -f4 | sed 's/v//' || echo "")
    fi

    # Try method 4: talosctl version
    if [ -z "$version" ]; then
        version=$(talosctl -n $CONTROL_PLANE_NODE version 2>/dev/null | grep "Kubernetes:" | awk '{print $2}' | sed 's/v//' || echo "")
    fi

    # Try method 5: Simple kubectl version
    if [ -z "$version" ]; then
        version=$(kubectl version --short 2>/dev/null | grep "Server Version" | awk '{print $3}' | sed 's/v//' || echo "")
    fi

    echo "$version"
}

# Function to compare Kubernetes versions
# Returns 0 if current >= target (skip upgrade)
# Returns 1 if current < target (needs upgrade)
k8s_version_compare() {
    local current=$1
    local target=$2

    # Handle empty versions
    if [ -z "$current" ] || [ -z "$target" ]; then
        return 1  # Needs upgrade if we can't determine version
    fi

    # Remove 'v' prefix if present
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
        if [ -z "${CURR[$i]}" ]; then CURR[$i]=0; fi
        if [ -z "${TARG[$i]}" ]; then TARG[$i]=0; fi
    done

    # Compare major version
    if [ "${CURR[0]}" -gt "${TARG[0]}" ]; then
        return 0
    elif [ "${CURR[0]}" -lt "${TARG[0]}" ]; then
        return 1
    fi

    # Compare minor version
    if [ "${CURR[1]}" -gt "${TARG[1]}" ]; then
        return 0
    elif [ "${CURR[1]}" -lt "${TARG[1]}" ]; then
        return 1
    fi

    # Compare patch version
    if [ "${CURR[2]}" -gt "${TARG[2]}" ]; then
        return 0
    elif [ "${CURR[2]}" -lt "${TARG[2]}" ]; then
        return 1
    fi

    return 0
}

# Function to upgrade Kubernetes
upgrade_k8s() {
    local target_version=$1

    log_info "Upgrading Kubernetes to v$target_version..."

    # Run dry-run first to check what will be upgraded
    log_info "Running dry-run to preview changes..."
    if ! talosctl -n $CONTROL_PLANE_NODE upgrade-k8s --to $target_version --dry-run 2>&1; then
        log_warn "Dry-run completed (warnings are normal)"
    fi

    echo ""
    log_warn "The above changes will be applied to the cluster"
    read -p "Proceed with upgrade to v$target_version? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_warn "Upgrade to v$target_version cancelled by user"
        return 1
    fi

    # Perform the actual upgrade
    log_info "Starting Kubernetes upgrade to v$target_version..."
    if ! talosctl -n $CONTROL_PLANE_NODE upgrade-k8s --to $target_version; then
        log_error "Upgrade to v$target_version failed"
        return 1
    fi

    log_info "✓ Kubernetes successfully upgraded to v$target_version"

    # Wait for cluster to stabilize
    log_info "Waiting 60s for cluster to stabilize..."
    sleep 60

    # Verify upgrade
    local new_version=$(get_k8s_version)
    if [ -n "$new_version" ]; then
        log_info "Current Kubernetes version: v$new_version"
    fi

    return 0
}

# Function to check cluster health
check_cluster_health() {
    log_info "Checking cluster health..."

    # Check if all nodes are ready
    local not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -v "Ready" | wc -l || echo "0")
    if [ "$not_ready" -gt 0 ]; then
        log_warn "$not_ready nodes are not ready"
        kubectl get nodes 2>/dev/null || true
    else
        log_info "All nodes are Ready"
    fi

    # Check critical pods
    log_info "Checking system pods..."
    kubectl get pods -n kube-system 2>/dev/null || log_warn "Could not get pod status"
}

# Main upgrade process
main() {
    log_info "========================================="
    log_info "Kubernetes Upgrade Script"
    log_info "========================================="
    log_info "Control Plane Node: $CONTROL_PLANE_NODE"
    log_info "VIP: $VIP"
    log_info "Target K8s Versions: ${K8S_VERSIONS[@]}"
    log_info "========================================="

    # Get current Kubernetes version
    log_info "Detecting current Kubernetes version..."
    local current_k8s=$(get_k8s_version)

    if [ -z "$current_k8s" ]; then
        log_error "Could not determine current Kubernetes version"
        log_info "Trying to show available information..."

        echo ""
        log_info "Kubectl version output:"
        kubectl version 2>&1 || true

        echo ""
        log_info "Talosctl version output:"
        talosctl -n $CONTROL_PLANE_NODE version 2>&1 || true

        echo ""
        log_info "Node information:"
        kubectl get nodes 2>&1 || true

        echo ""
        log_error "Please manually specify the current version or check cluster connectivity"
        read -p "Enter current Kubernetes version (e.g., 1.30.0) or 'exit' to quit: " manual_version

        if [ "$manual_version" == "exit" ]; then
            exit 1
        fi

        current_k8s="$manual_version"
    fi

    log_info "Current Kubernetes version: v$current_k8s"

    # Determine which versions need to be applied
    local needed_versions=()
    for version in "${K8S_VERSIONS[@]}"; do
        if ! k8s_version_compare "$current_k8s" "$version"; then
            needed_versions+=("$version")
        fi
    done

    if [ ${#needed_versions[@]} -eq 0 ]; then
        log_info "Kubernetes is already at or above v1.34.1!"
        log_info "No upgrades needed."
        exit 0
    fi

    log_info "Versions that will be applied: ${needed_versions[@]}"
    echo ""

    log_warn "IMPORTANT: Kubernetes can only skip one minor version during upgrade"
    log_warn "This script will upgrade through each minor version sequentially"
    echo ""

    read -p "Proceed with Kubernetes upgrade? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_warn "Upgrade cancelled by user"
        exit 0
    fi

    # Check initial cluster health
    check_cluster_health
    echo ""

    # Loop through each version
    for version in "${needed_versions[@]}"; do
        log_info "========================================="
        log_info "Target K8s Version: v$version"
        log_info "========================================="

        upgrade_k8s $version || {
            log_error "Failed to upgrade to v$version"
            log_error "Manual intervention may be required"
            exit 1
        }

        log_info "========================================="
        log_info "Kubernetes v$version upgrade complete"
        log_info "========================================="

        # Check cluster health after upgrade
        check_cluster_health

        # Wait before next version
        if [ "$version" != "${needed_versions[-1]}" ]; then
            log_info "Waiting 90s before next version upgrade..."
            sleep 90
        fi
    done

    # Final verification
    log_info "========================================="
    log_info "All Kubernetes Upgrades Complete!"
    log_info "========================================="

    local final_version=$(get_k8s_version)
    if [ -n "$final_version" ]; then
        log_info "Final Kubernetes version: v$final_version"
    fi

    log_info "Final cluster status:"
    kubectl get nodes -o wide 2>/dev/null || log_warn "Could not get node status"

    log_info ""
    log_info "Checking system pods:"
    kubectl get pods -n kube-system 2>/dev/null || log_warn "Could not get pod status"

    log_info ""
    log_info "✓ Kubernetes upgrade process complete"
    log_warn "Please verify your workloads are functioning correctly"
}

# Run main function
main
