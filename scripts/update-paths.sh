#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Path Update Script ===${NC}"
echo "This will update all path references in kubernetes/main/"
echo ""
read -p "Have you backed up your work? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    echo -e "${RED}Aborting. Please backup first!${NC}"
    exit 1
fi

echo -e "${YELLOW}Finding all YAML files in kubernetes/main/${NC}"
FILE_COUNT=$(find kubernetes/main -name "*.yaml" -type f | wc -l | tr -d ' ')
echo "Found ${FILE_COUNT} YAML files"
echo ""

# Function to replace paths
replace_path() {
    local old_path=$1
    local new_path=$2
    local description=$3

    echo -e "${YELLOW}Updating: ${description}${NC}"
    find kubernetes/main -name "*.yaml" -type f -exec sed -i.bak \
        "s|${old_path}|${new_path}|g" {} \;
    echo -e "${GREEN}✓ Done${NC}"
}

# Infrastructure controllers
replace_path \
    "kubernetes/apps/kube-system/cilium" \
    "kubernetes/main/infrastructure/controllers/cilium" \
    "Cilium paths"

replace_path \
    "kubernetes/apps/kube-system/coredns" \
    "kubernetes/main/infrastructure/controllers/coredns" \
    "CoreDNS paths"

# Infrastructure configs
replace_path \
    "kubernetes/apps/kube-system/kubelet-csr-approver" \
    "kubernetes/main/infrastructure/configs/kubelet-csr-approver" \
    "Kubelet CSR Approver paths"

# Platform services
replace_path \
    "kubernetes/apps/cert-manager" \
    "kubernetes/main/platform/cert-manager" \
    "cert-manager paths"

replace_path \
    "kubernetes/apps/external-dns" \
    "kubernetes/main/platform/external-dns" \
    "external-dns paths"

replace_path \
    "kubernetes/apps/external-secrets" \
    "kubernetes/main/platform/external-secrets" \
    "external-secrets paths"

replace_path \
    "kubernetes/apps/observability" \
    "kubernetes/main/platform/observability" \
    "Observability paths"

# Platform security
replace_path \
    "kubernetes/apps/kube-system/reflector" \
    "kubernetes/main/platform/security/reflector" \
    "Reflector paths"

replace_path \
    "kubernetes/apps/kube-system/reloader" \
    "kubernetes/main/platform/security/reloader" \
    "Reloader paths"

# Platform operators
replace_path \
    "kubernetes/apps/actions-runner-system" \
    "kubernetes/main/platform/operators/actions-runner-controller" \
    "Actions Runner Controller paths"

replace_path \
    "kubernetes/apps/volsync-system" \
    "kubernetes/main/platform/operators/volsync" \
    "Volsync paths"

# Applications
replace_path \
    "kubernetes/apps/database" \
    "kubernetes/main/apps/database" \
    "Database paths"

replace_path \
    "kubernetes/apps/artemis-cluster" \
    "kubernetes/main/apps/artemis-cluster" \
    "Artemis Cluster app paths"

replace_path \
    "kubernetes/apps/external-services" \
    "kubernetes/main/apps/external-services" \
    "External Services paths"

# Flux config
replace_path \
    "kubernetes/flux/vars" \
    "kubernetes/flux/config" \
    "Flux vars to config"

echo ""
echo -e "${GREEN}=== Path updates complete! ===${NC}"
echo ""
echo -e "${YELLOW}Backup files created with .bak extension${NC}"
echo "Review changes with: git diff kubernetes/main/"
echo ""
echo "If everything looks good, remove backups:"
echo "  find kubernetes/main -name '*.bak' -delete"
