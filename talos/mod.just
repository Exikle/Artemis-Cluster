set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

# scripts_dir := justfile_dir() + '/scripts'

talos_dir := justfile_dir() + '/talos'
controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`

[private]
default:
    just -l talos

echo-path:
    echo {{ talos_dir }}

[doc('Render Talos config for a node')]
render-config node:
    export IS_CONTROLLER="$(just talos machine-controller {{ node }})"; \
    talosctl machineconfig patch <(just template "{{ talos_dir }}/machineconfig-new.yaml.j2") \
        -p @<(just template "{{ talos_dir }}/nodes/{{ node }}.yaml.j2")

[private]
machine-controller node:
    just template "{{ talos_dir }}/nodes/{{ node }}.yaml.j2" | yq -e 'select(.machine) | (.machine.type == "controlplane") // ""'

[doc('Generate Talos machine configs using talhelper')]
genconfig:
    talhelper genconfig --secret-file talsecret.secret.sops.yaml

[doc('Apply Talos config to a node')]
apply-node node *args:
    talosctl apply-config -n {{ node }} --file {{ talos_dir }}/clusterconfig/artemis-cluster-{{ node }}.yaml {{ args }}

[doc('Retrieve kubeconfig from Talos cluster')]
retreive-kubeconfig *args:
    - talosctl kubeconfig --nodes {{ controller }} {{ args }}

[doc('Check Talos cluster health')]
check-cluster-health:
    - talosctl health --nodes {{ controller }}

[doc('Shutdown a node')]
shutdown-node node *args:
    gum confirm "Shutdown node {{ node }}?" --default="No" && \
        talosctl -n "{{ node }}" shutdown --force {{ args }} || exit 0

[doc('Open Talos dashboard')]
open-dashboard:
    - talosctl dashboard --nodes {{ controller }}

# [doc('Generate schematic ID from Talos schematic')]
# gen-schematic-id:
#     curl -sX POST --data-binary @<(just template "{{ talos_dir }}/schematic.yaml.j2") "https://factory.talos.dev/schematics" | jq -r '.id'
