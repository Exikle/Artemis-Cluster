set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

talos_dir := justfile_dir() + '/talos'
controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`

[private]
default:
    just -l talos

[doc('Apply Talos config to a node')]
apply-node node *args:
    just talos render-config "{{ node }}" | talosctl -n "{{ node }}" apply-config -f /dev/stdin {{ args }}

[doc('Download Talos machine image for a schematic (e.g. controlplane, worker, gpu)')]
download-image version schematic:
    schematic_id=$(just talos gen-schematic-id {{ schematic }}); \
    gum spin --title "Downloading Talos {{ version }} ({{ schematic }}) ..." -- \
    curl -sfL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors \
        -o "{{ talos_dir }}/talos-{{ version }}-{{ schematic }}.iso" \
        "https://factory.talos.dev/image/${schematic_id}/{{ version }}/metal-amd64-secureboot.iso"

[doc('Generate schematic ID from a schematic file (e.g. controlplane, worker, gpu)')]
gen-schematic-id schematic:
    curl -sX POST --data-binary @"{{ talos_dir }}/schematics/{{ schematic }}.yaml" "https://factory.talos.dev/schematics" | jq -r '.id'

[doc('Reboot a node')]
reboot-node node:
    gum confirm "Reboot node {{ node }}?" --default="No" && \
        talosctl -n {{ node }} reboot -m powercycle || exit 0

[doc('Render Talos config for a node')]
render-config node:
    export IS_CONTROLLER="$(just talos machine-controller {{ node }})"; \
    talosctl machineconfig patch <(just template "{{ talos_dir }}/machineconfig.yaml.j2") \
        -p @<(just template "{{ talos_dir }}/nodes/{{ node }}.yaml.j2")

[doc('Reset a node')]
reset-node node *args:
    gum confirm "Reset node {{ node }}?" --default="No" && \
        talosctl -n "{{ node }}" reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --graceful=false {{ args }} || exit 0

[doc('Retrieve kubeconfig from Talos cluster')]
retreive-kubeconfig *args:
    - talosctl kubeconfig --nodes {{ controller }} {{ args }}

[doc('Check Talos cluster health')]
check-cluster-health:
    - talosctl health --nodes {{ controller }}

[doc('Open Talos dashboard')]
open-dashboard:
    - talosctl dashboard --nodes {{ controller }}

[doc('Shutdown a node')]
shutdown-node node *args:
    gum confirm "Shutdown node {{ node }}?" --default="No" && \
        talosctl -n "{{ node }}" shutdown --force {{ args }} || exit 0

[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -n "{{ controller }}" upgrade-k8s --to {{ version }}

[doc('Upgrade Talos version on a node')]
upgrade-node node *args:
    talosctl -n "{{ node }}" upgrade -i "$(just talos machine-image {{ node }})" -m powercycle --timeout=10m {{ args }}

[private]
machine-controller node:
    just template "{{ talos_dir }}/nodes/{{ node }}.yaml.j2" | yq -e 'select(.machine) | (.machine.type == "controlplane") // ""'

[private]
machine-image node:
    just template "{{ talos_dir }}/nodes/{{ node }}.yaml.j2" | yq -e 'select(.machine) | .machine.install.image'
