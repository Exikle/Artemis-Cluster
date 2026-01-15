set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

# scripts_dir := justfile_dir() + '/scripts'
# talos_dir := justfile_dir() + '/talos'
kube_dir := justfile_dir() + '/kubernetes'
# controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`

[private]
default:
    just -l kube

[doc('Prune pods in Failed, Pending, or Succeeded state')]
prune-pods:
    for phase in Failed Pending Succeeded; do \
        kubectl delete pods -A --field-selector status.phase="$phase" --ignore-not-found=true; \
    done

[doc('Get Events')]
events:
    kubectl get events -A --sort-by='.lastTimestamp' | tail -50

[doc('Reconcile Artemis Cluster')]
reconcile-cluster:
    flux reconcile ks artemis-cluster --with-source

[doc('Sync ExternalSecrets')]
sync-es:
    kubectl get es --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite es "$name" force-sync="$(date +%s)"; \
    done

[doc('Sync GitRepositories')]
sync-git:
    kubectl get gitrepo --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite gitrepo "$name" reconcile.fluxcd.io/requestedAt="$(date +%s)"; \
    done

[doc('Sync HelmReleases')]
sync-hr:
    kubectl get hr --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite hr "$name" reconcile.fluxcd.io/requestedAt="$(date +%s)" reconcile.fluxcd.io/forceAt="$(date +%s)"; \
    done

[doc('Sync Kustomizations')]
sync-ks:
    kubectl get ks --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite ks "$name" reconcile.fluxcd.io/requestedAt="$(date +%s)"; \
    done

[doc('Sync OCIRepositories')]
sync-oci:
    kubectl get ocirepo --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite ocirepo "$name" reconcile.fluxcd.io/requestedAt="$(date +%s)"; \
    done

[doc('Run Flux Local Test')]
test:
    podman run --rm \
      -u 0 \
      --security-opt label=disable \
      -v "`git rev-parse --show-toplevel`:/github/workspace" \
      -e GIT_CONFIG_COUNT=1 \
      -e GIT_CONFIG_KEY_0=safe.directory \
      -e GIT_CONFIG_VALUE_0=* \
      ghcr.io/allenporter/flux-local:v8.1.0 \
      test --all-namespaces --enable-helm \
      --path /github/workspace/kubernetes/flux \
      --sources flux-system=/github/workspace

[doc('Run Flux Local Diff')]
diff:
    podman run --rm \
      -u 0 \
      --security-opt label=disable \
      -v "`git rev-parse --show-toplevel`:/github/workspace" \
      -e GIT_CONFIG_COUNT=1 \
      -e GIT_CONFIG_KEY_0=safe.directory \
      -e GIT_CONFIG_VALUE_0=* \
      ghcr.io/allenporter/flux-local:v8.1.0 \
      diff helmrelease --unified 6 \
      --path /github/workspace/kubernetes/flux \
      --sources flux-system=/github/workspace
