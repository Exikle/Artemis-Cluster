# set positional-arguments := true
# set quiet := true
# set shell := ['bash', '-euo', 'pipefail', '-c']

# bootstrap_dir := justfile_dir() + '/bootstrap'
# secrets_dir := bootstrap_dir + '/helmfile.d/secrets'
# kubernetes_dir := justfile_dir() + '/kubernetes'
# controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`
# nodes := `talosctl config info -o yaml | yq -e '.nodes | join (" ")'`

# [private]
# default: talos kube (kubeconfig "node") wait namespaces crds resources apps kubeconfig

# [doc('Install Talos')]
# talos:
#     just log info "Running stage..." "stage" "$0"
#     for n in {{ nodes }}; do \
#         # RENAMED: 'op' -> 'output' to avoid confusion with 1Password CLI
#         if ! output=$(just talos apply-node "$n" --insecure 2>&1); then \
#             if [[ "$output" == *"certificate required"* ]]; then \
#                 just log info "Talos already configured, skipping apply of config" "stage" "$0" "node" "$n"; \
#                 continue; \
#             fi; \
#             just log fatal "Failed to apply Talos configuration" "stage" "$0" "node" "$n" "output" "$output"; \
#         fi; \
#     done

# [doc('Install Kubernetes')]
# kube:
#     just log info "Running stage..." "stage" "$0"
#     # RENAMED: 'op' -> 'output'
#     until output=$(talosctl -n "{{ controller }}" bootstrap 2>&1 || true) && [[ "$output" == *"AlreadyExists"* ]]; do \
#         just log info "Kubernetes bootstrap in progress. Retrying in 5 seconds..." "stage" "$0"; \
#         sleep 5; \
#     done

# [doc('Fetch kubeconfig')]
# kubeconfig lb="cilium":
#     just log info "Running stage..." "stage" "$0"
#     if ! talosctl kubeconfig -n "{{ controller }}" -f --force-context-name main {{ justfile_dir() }}; then \
#         just log fatal "Failed to fetch kubeconfig" "stage" "$0"; \
#     fi
#     if [[ "{{ lb }}" != "cilium" ]]; then \
#         if ! kubectl config set-cluster main --server "https://{{ controller }}:6443"; then \
#             just log fatal "Failed to set kubectl cluster server address" "stage" "$0"; \
#         fi; \
#     fi

# [doc('Wait for nodes to be not-ready')]
# wait:
#     just log info "Running stage..." "stage" "$0"
#     if ! kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then \
#         until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do \
#             just log info "Nodes not available, waiting for nodes to be available. Retrying in 5 seconds..." "stage" "$0"; \
#             sleep 5; \
#         done \
#     fi

# [doc('Apply Kubernetes namespaces')]
# namespaces:
#     just log info "Running stage..." "stage" "$0"
#     find "{{ kubernetes_dir }}/apps" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do \
#         if ! kustomize build "$dir" | yq ea -e 'select(.kind == "Namespace")' | kubectl apply --server-side --field-manager bootstrap --force-conflicts -f -; then \
#             just log fatal "Failed to apply namespace" "stage" "$0" "namespace" "$(basename "$dir")"; \
#         fi; \
#     done

# [doc('Apply Helmfile CRDs')]
# crds:
#     just log info "Running stage..." "stage" "$0"
#     if ! helmfile -f "{{ bootstrap_dir }}/helmfile.d/00-crds.yaml" apply; then \
#         just log fatal "Failed to apply crds" "stage" "$0"; \
#     fi;

# [doc('Apply Secrets & Resources')]
# resources:
#     just log info "Running stage..." "stage" "$0"
#     # 1. Decrypt Age Key
#     export AGE_KEY=$(sops -d --extract '["stringData"]["age.agekey"]' {{ secrets_dir }}/age-key.secret.sops.yaml) && \
#     # 2. Decrypt Bitwarden Creds
#     export BW_ACCESS_TOKEN=$(sops -d --extract '["stringData"]["ACCESS_TOKEN"]' {{ secrets_dir }}/bitwarden-provider.secret.sops.yaml) && \
#     export BW_PROJECT_ID=$(sops -d --extract '["stringData"]["PROJECT_ID"]' {{ secrets_dir }}/bitwarden-provider.secret.sops.yaml) && \
#     export BW_ORG_ID=$(sops -d --extract '["stringData"]["ORG_ID"]' {{ secrets_dir }}/bitwarden-provider.secret.sops.yaml) && \
#     # 3. Decrypt GitHub Deploy Key
#     export GH_IDENTITY=$(sops -d --extract '["stringData"]["identity"]' {{ secrets_dir }}/github.secret.sops.yaml) && \
#     export GH_KNOWN_HOSTS=$(sops -d --extract '["stringData"]["known_hosts"]' {{ secrets_dir }}/github.secret.sops.yaml) && \
#     # 4. Render Template & Apply
#     just template "{{ bootstrap_dir }}/resources.yaml.j2" | \
#     kubectl apply --server-side --field-manager bootstrap --force-conflicts -f -

# [doc('Apply Helmfile Apps')]
# apps:
#     just log info "Running stage..." "stage" "$0"
#     if ! helmfile -f "{{ bootstrap_dir }}/helmfile.d/01-apps.yaml" apply --hide-notes; then \
#         just log fatal "Failed to sync helmfile" "stage" "$0"; \
#     fi
