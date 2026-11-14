set default-list
set default-script
set no-exit-message
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

context := env('KUBE_CONTEXT', 'artemis')
kubectl := "kubectl --context " + context

# Pinned so a shell without mise's env cannot write the bootstrap kubeconfig, or read it,
# from ~/.kube/config. `talosctl kubeconfig` writes this same path.
export KUBECONFIG := justfile_dir() / "kubeconfig"

# .endpoints is the control planes and only the control planes. Do NOT use .nodes here:
# it is a hand-set single entry, not the fleet — the node list comes from talos/nodes.
controller := `talosctl config info -o yaml | yq -r -e '.endpoints[0]'`
controlplanes := `talosctl config info -o yaml | yq -r -e '.endpoints | join (" ")'`

[confirm('Bootstrap cluster? [y|N]')]
[doc('Bootstrap a Talos & Kubernetes cluster end-to-end')]
cluster: nodes k8s (kubeconfig "node") base apps kubeconfig

[private]
nodes:
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    for n in $(just bootstrap node-list); do
        if ! op=$(just --yes talos apply-node "$n" --insecure 2>&1); then
            if [[ "$op" == *"certificate required"* ]]; then
                just log info "Talos already configured, skipping apply of config" "stage" "{{ recipe_name() }}" "node" "$n"
                continue
            fi
            just log fatal "Failed to apply Talos configuration" "stage" "{{ recipe_name() }}" "node" "$n" "output" "$op"
        fi
    done

[private]
k8s:
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    until op=$(talosctl -n "{{ controller }}" bootstrap 2>&1 || true) && [[ "$op" == *"AlreadyExists"* ]]; do
        just log info "Kubernetes bootstrap in progress. Retrying in 5 seconds..." "stage" "{{ recipe_name() }}"
        sleep 5
    done

[private]
kubeconfig lb="cilium":
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    if ! talosctl kubeconfig -n "{{ controller }}" -f --force-context-name {{ context }} {{ justfile_dir() }}; then
        just log fatal "Failed to fetch kubeconfig" "stage" "{{ recipe_name() }}"
    fi
    if [[ "{{ lb }}" != "cilium" ]]; then
        # --force-context-name renames the CONTEXT; the cluster entry keeps the Talos cluster
        # name, so set-cluster has to be told that name or it creates a dangling entry.
        cluster="$(kubectl config view -o yaml | yq -r -e '.contexts[] | select(.name == "{{ context }}") | .context.cluster')"
        if ! kubectl config set-cluster "$cluster" --server "https://{{ controller }}:6443"; then
            just log fatal "Failed to set kubectl cluster server address" "stage" "{{ recipe_name() }}"
        fi
    fi

[private]
base: api-ready nodes-ready
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    find "{{ justfile_dir() }}/kubernetes/apps" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do
        if ! kustomize build "$dir" | yq ea -r -e 'select(.kind == "Namespace")' | {{ kubectl }} apply --server-side --field-manager kustomize-controller --force-conflicts -f -; then
            just log fatal "Failed to apply namespace" "stage" "{{ recipe_name() }}" "namespace" "$(basename "$dir")"
        fi
    done
    if ! just template "{{ source_directory() }}/resources.yaml.j2" | {{ kubectl }} apply --server-side --field-manager kustomize-controller --force-conflicts -f -; then
        just log fatal "Failed to apply resources" "stage" "{{ recipe_name() }}"
    fi
    if ! helmfile -f "{{ source_directory() }}/helmfile.d/00-crds.yaml" template -q | yq ea -r -e 'select(.kind == "CustomResourceDefinition")' | {{ kubectl }} apply --server-side --field-manager kustomize-controller --force-conflicts -f -; then
        just log fatal "Failed to apply crds" "stage" "{{ recipe_name() }}"
    fi

[private]
apps:
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    if ! helmfile --kube-context {{ context }} -f "{{ source_directory() }}/helmfile.d/01-apps.yaml" sync --hide-notes; then
        just log fatal "Failed to sync helmfile" "stage" "{{ recipe_name() }}"
    fi

# Wait until every control plane answers /readyz. Helm and kubectl calls after this stage
# are not retried. Control planes only — a worker has nothing listening on 6443 and this
# would wait on it forever.
[private]
api-ready:
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    for n in {{ controlplanes }}; do
        until [[ "$(curl -ks -o /dev/null -w '%{http_code}' --connect-timeout 2 "https://${n}:6443/readyz")" == "200" ]]; do
            just log info "Waiting for kube-apiserver. Retrying in 5 seconds..." "stage" "{{ recipe_name() }}" "node" "$n"
            sleep 5
        done
    done

# Wait until nodes register as Ready=False. They only become Ready=True once the CNI is healthy.
[private]
nodes-ready:
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    if ! {{ kubectl }} wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        until {{ kubectl }} wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
            just log info "Nodes not available, waiting for nodes to be available. Retrying in 5 seconds..." "stage" "{{ recipe_name() }}"
            sleep 5
        done
    fi

# The fleet, control planes first. talos/nodes is ground truth — `talosctl config info`
# reports one hand-set node, and its .nodes are IPs while every template, and the
# schematic-type case in talos/mod.just, is keyed on hostname (ymir must resolve to the
# `metal` schematic, not `worker`). Control planes lead so a partial failure is readable.
[private]
node-list:
    all="$(find "{{ justfile_dir() }}/talos/nodes" -name '*.yaml.j2' -exec basename {} .yaml.j2 \; | sort)"
    printf '%s\n' "$all" | grep -- '-cp-' || true
    printf '%s\n' "$all" | grep -v -- '-cp-' || true
