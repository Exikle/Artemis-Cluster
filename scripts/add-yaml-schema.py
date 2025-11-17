#!/usr/bin/env python3

import os
import re
from pathlib import Path

# Official Kubernetes schemas
K8S_VERSION = "v1.34.0"
K8S_SCHEMA_BASE = f"https://kubernetesjsonschema.dev/{K8S_VERSION}"

SCHEMA_MAPPINGS = {
    # Core Kubernetes resources
    "Deployment": f"{K8S_SCHEMA_BASE}/deployment-apps-v1.json",
    "Service": f"{K8S_SCHEMA_BASE}/service-v1.json",
    "ConfigMap": f"{K8S_SCHEMA_BASE}/configmap-v1.json",
    "Secret": f"{K8S_SCHEMA_BASE}/secret-v1.json",
    "StatefulSet": f"{K8S_SCHEMA_BASE}/statefulset-apps-v1.json",
    "DaemonSet": f"{K8S_SCHEMA_BASE}/daemonset-apps-v1.json",
    "Pod": f"{K8S_SCHEMA_BASE}/pod-v1.json",
    "Namespace": f"{K8S_SCHEMA_BASE}/namespace-v1.json",
    "PersistentVolumeClaim": f"{K8S_SCHEMA_BASE}/persistentvolumeclaim-v1.json",
    "PersistentVolume": f"{K8S_SCHEMA_BASE}/persistentvolume-v1.json",
    "Ingress": f"{K8S_SCHEMA_BASE}/ingress-networking-v1.json",
    "ServiceAccount": f"{K8S_SCHEMA_BASE}/serviceaccount-v1.json",
    "Role": f"{K8S_SCHEMA_BASE}/role-rbac-v1.json",
    "RoleBinding": f"{K8S_SCHEMA_BASE}/rolebinding-rbac-v1.json",
    "ClusterRole": f"{K8S_SCHEMA_BASE}/clusterrole-rbac-v1.json",
    "ClusterRoleBinding": f"{K8S_SCHEMA_BASE}/clusterrolebinding-rbac-v1.json",
    "Job": f"{K8S_SCHEMA_BASE}/job-batch-v1.json",
    "CronJob": f"{K8S_SCHEMA_BASE}/cronjob-batch-v1.json",
    "StorageClass": f"{K8S_SCHEMA_BASE}/storageclass-storage-v1.json",
    "NetworkPolicy": f"{K8S_SCHEMA_BASE}/networkpolicy-networking-v1.json",
    "ResourceQuota": f"{K8S_SCHEMA_BASE}/resourcequota-v1.json",
    "LimitRange": f"{K8S_SCHEMA_BASE}/limitrange-v1.json",
    "HorizontalPodAutoscaler": f"{K8S_SCHEMA_BASE}/horizontalpodautoscaler-autoscaling-v2.json",
    "VolumeSnapshotClass": f"{K8S_SCHEMA_BASE}/volumesnapshotclass-snapshot-v1.json",
    "VolumeSnapshot": f"{K8S_SCHEMA_BASE}/volumesnapshot-snapshot-v1.json",
    "PodDisruptionBudget": f"{K8S_SCHEMA_BASE}/poddisruptionbudget-policy-v1.json",
    "PriorityClass": f"{K8S_SCHEMA_BASE}/priorityclass-scheduling-v1.json",

    # Flux CD resources
    "HelmRelease": "https://kubernetes-schemas.pages.dev/helmrelease_v2.json",
    "Kustomization": "https://kubernetes-schemas.pages.dev/kustomization_v1.json",
    "HelmRepository": "https://kubernetes-schemas.pages.dev/helmrepository_v1.json",
    "GitRepository": "https://kubernetes-schemas.pages.dev/gitrepository_v1.json",
    "OCIRepository": "https://kubernetes-schemas.pages.dev/ocirepository_v1beta2.json",
    "ImageRepository": "https://kubernetes-schemas.pages.dev/imagerepository_v1beta2.json",
    "ImagePolicy": "https://kubernetes-schemas.pages.dev/imagepolicy_v1beta2.json",
    "ImageUpdateAutomation": "https://kubernetes-schemas.pages.dev/imageupdateautomation_v1beta2.json",
    "Receiver": "https://kubernetes-schemas.pages.dev/receiver_v1.json",
    "Alert": "https://kubernetes-schemas.pages.dev/alert_v1beta3.json",
    "Provider": "https://kubernetes-schemas.pages.dev/provider_v1beta3.json",

    # Gateway API
    "Gateway": "https://kubernetes-schemas.pages.dev/gateway_v1.json",
    "GatewayClass": "https://kubernetes-schemas.pages.dev/gatewayclass_v1.json",
    "HTTPRoute": "https://kubernetes-schemas.pages.dev/httproute_v1.json",
    "GRPCRoute": "https://kubernetes-schemas.pages.dev/grpcroute_v1.json",
    "TCPRoute": "https://kubernetes-schemas.pages.dev/tcproute_v1alpha2.json",
    "UDPRoute": "https://kubernetes-schemas.pages.dev/udproute_v1alpha2.json",
    "TLSRoute": "https://kubernetes-schemas.pages.dev/tlsroute_v1alpha2.json",
    "ReferenceGrant": "https://kubernetes-schemas.pages.dev/referencegrant_v1beta1.json",

    # Cert-manager
    "Certificate": "https://kubernetes-schemas.pages.dev/certificate_v1.json",
    "ClusterIssuer": "https://kubernetes-schemas.pages.dev/clusterissuer_v1.json",
    "Issuer": "https://kubernetes-schemas.pages.dev/issuer_v1.json",
    "CertificateRequest": "https://kubernetes-schemas.pages.dev/certificaterequest_v1.json",

    # External Secrets
    "ExternalSecret": "https://kubernetes-schemas.pages.dev/externalsecret_v1beta1.json",
    "SecretStore": "https://kubernetes-schemas.pages.dev/secretstore_v1beta1.json",
    "ClusterSecretStore": "https://kubernetes-schemas.pages.dev/clustersecretstore_v1beta1.json",
    "PushSecret": "https://kubernetes-schemas.pages.dev/pushsecret_v1alpha1.json",

    # Cilium
    "CiliumNetworkPolicy": "https://kubernetes-schemas.pages.dev/ciliumnetworkpolicy_v2.json",
    "CiliumClusterwideNetworkPolicy": "https://kubernetes-schemas.pages.dev/ciliumclusterwidenetworkpolicy_v2.json",
    "CiliumLoadBalancerIPPool": "https://kubernetes-schemas.pages.dev/ciliumloadbalancerippool_v2alpha1.json",
    "CiliumL2AnnouncementPolicy": "https://kubernetes-schemas.pages.dev/ciliuml2announcementpolicy_v2alpha1.json",

    # VolSync
    "ReplicationSource": "https://kubernetes-schemas.pages.dev/replicationsource_v1alpha1.json",
    "ReplicationDestination": "https://kubernetes-schemas.pages.dev/replicationdestination_v1alpha1.json",

    # Prometheus Operator
    "ServiceMonitor": "https://kubernetes-schemas.pages.dev/servicemonitor_v1.json",
    "PodMonitor": "https://kubernetes-schemas.pages.dev/podmonitor_v1.json",
    "Prometheus": "https://kubernetes-schemas.pages.dev/prometheus_v1.json",
    "PrometheusRule": "https://kubernetes-schemas.pages.dev/prometheusrule_v1.json",
    "Alertmanager": "https://kubernetes-schemas.pages.dev/alertmanager_v1.json",

    # CloudNative-PG
    "Cluster": "https://kubernetes-schemas.pages.dev/cluster_v1.json",
    "Backup": "https://kubernetes-schemas.pages.dev/backup_v1.json",
    "ScheduledBackup": "https://kubernetes-schemas.pages.dev/scheduledbackup_v1.json",
    "Pooler": "https://kubernetes-schemas.pages.dev/pooler_v1.json",
}

def detect_kind(yaml_file):
    """Detect the kind from a YAML file using regex (no yaml library needed)."""
    try:
        with open(yaml_file, 'r', encoding='utf-8') as f:
            content = f.read()

        # Simple regex to find "kind: Something"
        match = re.search(r'^kind:\s*(\S+)', content, re.MULTILINE)
        if match:
            return match.group(1).strip()
    except Exception as e:
        print(f"⚠  Could not parse {yaml_file}: {e}")

    return None

def has_schema_modeline(yaml_file):
    """Check if file already has a schema modeline."""
    try:
        with open(yaml_file, 'r', encoding='utf-8') as f:
            first_lines = [next(f, '') for _ in range(5)]

        for line in first_lines:
            if 'yaml-language-server' in line and '$schema=' in line:
                return True
    except:
        pass

    return False

def add_schema_to_file(yaml_file, schema_url):
    """Add schema modeline to the file."""
    try:
        with open(yaml_file, 'r', encoding='utf-8') as f:
            content = f.read()

        # Create schema modeline
        schema_line = f"# yaml-language-server: $schema={schema_url}\n"

        # Check if file starts with "---"
        if content.startswith("---"):
            # Insert schema line before "---"
            new_content = schema_line + content
        else:
            # Add both schema line and "---"
            new_content = schema_line + "---\n" + content

        with open(yaml_file, 'w', encoding='utf-8') as f:
            f.write(new_content)

        return True
    except Exception as e:
        print(f"❌ Error modifying {yaml_file}: {e}")
        return False

def process_yaml_files(directory=".", exclude_dirs=None):
    """Process all YAML files in the directory."""
    if exclude_dirs is None:
        exclude_dirs = {'.git', 'templates', 'node_modules', '.venv', 'venv'}

    modified_count = 0
    skipped_count = 0
    unknown_kind_count = 0
    total_files = 0

    print("🔍 Scanning for YAML files to add schemas...")
    print(f"📚 Using official Kubernetes schemas from: {K8S_SCHEMA_BASE}")
    print("")

    for yaml_file in Path(directory).rglob("*.yaml"):
        # Skip excluded directories
        if any(excluded in yaml_file.parts for excluded in exclude_dirs):
            continue

        total_files += 1

        # Check if already has schema
        if has_schema_modeline(yaml_file):
            print(f"✓  Already has schema: {yaml_file}")
            skipped_count += 1
            continue

        # Detect kind
        kind = detect_kind(yaml_file)

        if not kind:
            print(f"⚠  Could not detect kind: {yaml_file}")
            unknown_kind_count += 1
            continue

        # Get schema URL
        schema_url = SCHEMA_MAPPINGS.get(kind)

        if not schema_url:
            print(f"⚠  No schema mapping for kind '{kind}': {yaml_file}")
            unknown_kind_count += 1
            continue

        # Add schema
        if add_schema_to_file(yaml_file, schema_url):
            print(f"📝 Added {kind} schema to: {yaml_file}")
            modified_count += 1

    print("\n================================")
    print("✅ Complete!")
    print(f"Total YAML files: {total_files}")
    print(f"Files modified: {modified_count}")
    print(f"Files skipped (already had schema): {skipped_count}")
    print(f"Files with unknown/unmapped kind: {unknown_kind_count}")
    print("================================")
    print(f"\n📖 Schema source: Official Kubernetes OpenAPI specs")

if __name__ == "__main__":
    process_yaml_files()
