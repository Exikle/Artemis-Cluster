set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l talos

[confirm('Apply Talos config to ' + node + ' [y|N] ?')]
[doc('Apply Talos config to a node')]
apply-node node *args:
    just talos render-config "{{ node }}" | talosctl -n "{{ node }}" apply-config -f /dev/stdin {{ args }}

[doc('Download Talos machine image for a schematic (e.g. controlplane, worker, gpu)')]
[script]
download-image version schematic:
    export SCHEMATIC="$(just talos schematic-id {{ schematic }})"
    curl -fL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors --progress-bar \
        -o "{{ source_directory() }}/talos-{{ version }}-{{ schematic }}.iso" \
        "https://factory.talos.dev/image/${SCHEMATIC}/{{ version }}/metal-amd64.iso"
    just log info "Downloaded Talos" version "{{ version }}" schematic "{{ schematic }}"

[doc('Show what applying the rendered config would change on a node')]
diff-node node:
    just talos render-config "{{ node }}" | talosctl -n "{{ node }}" apply-config -f /dev/stdin --dry-run

[confirm('Reboot node ' + node + ' [y|N] ?')]
[doc('Reboot a node')]
reboot-node node:
    talosctl -n {{ node }} reboot -m powercycle

[doc('Render Talos config for a node')]
[script]
render-config node:
    type="$(just talos machine-type {{ node }})"
    export SCHEMATIC="$(just talos schematic-id "$(just talos schematic-type {{ node }})")"
    talosctl machineconfig patch <(just template "{{ source_directory() }}/cluster.yaml.j2") \
        -p @<(just template "{{ source_directory() }}/${type}.yaml.j2") \
        -p @<(just template "{{ source_directory() }}/nodes/{{ node }}.yaml.j2")

[confirm('Reset node ' + node + ' [y|N] ?')]
[doc('Reset a node')]
reset-node node *args:
    talosctl -n "{{ node }}" reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --graceful=false {{ args }}

[confirm('Shutdown node ' + node + ' [y|N] ?')]
[doc('Shutdown a node')]
shutdown-node node *args:
    talosctl -n "{{ node }}" shutdown --force {{ args }}

[confirm('Upgrade Kubernetes to ' + version + ' [y|N] ?')]
[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -n "$(talosctl config info -o yaml | yq -r -e '.endpoints[0]')" upgrade-k8s --to {{ version }}

[confirm('Upgrade node ' + node + ' [y|N] ?')]
[doc('Upgrade Talos version on a node')]
upgrade-node node *args:
    talosctl -n "{{ node }}" upgrade -i "$(just talos machine-image {{ node }})" -m powercycle --timeout=10m {{ args }}

[doc('Validate the rendered config for a node, or every node if omitted')]
[script]
validate node="":
    nodes="{{ node }}"
    if [[ -z "${nodes}" ]]; then
        nodes="$(find "{{ source_directory() }}/nodes" -name '*.yaml.j2' -exec basename {} .yaml.j2 \; | sort)"
    fi
    rc=0
    for n in ${nodes}; do
        if just talos render-config "${n}" | talosctl validate -m metal -c /dev/stdin >/dev/null 2>&1; then
            just log info "Config valid" node "${n}"
        else
            just log error "Config INVALID" node "${n}"
            rc=1
        fi
    done
    exit "${rc}"

# Selects which of controlplane.yaml.j2 / worker.yaml.j2 `render-config` layers on.
[private]
machine-type node:
    just template "{{ source_directory() }}/nodes/{{ node }}.yaml.j2" | yq -r -e 'select(.machine) | .machine.type'

# Reads the installer image from the base config, where it is defined once with the
# schematic ID interpolated. Calls minijinja-cli directly rather than `just template`
# so `upgrade-node` keeps working without a 1Password session — the base config's
# op:// refs pass through as literals, which YAML still parses fine.
[private]
[script]
machine-image node:
    export SCHEMATIC="$(just talos schematic-id "$(just talos schematic-type {{ node }})")"
    minijinja-cli "{{ source_directory() }}/cluster.yaml.j2" \
        | yq -r -e 'select(.kind == "UnattendedInstallConfig") | .installer.image'

# `worker` carries siderolabs/qemu-guest-agent for the Proxmox VMs. On bare metal
# that service can never come up, and Talos blocks its boot sequence waiting for
# it until the phase times out and the node reboots — roughly every 70 minutes.
# Bare-metal workers therefore get `metal`, which is `worker` without it.
[private]
schematic-type node:
    case "{{ node }}" in \
      *-cp-*) echo "controlplane" ;; \
      *-gpu-*) echo "gpu" ;; \
      ymir) echo "metal" ;; \
      *) echo "worker" ;; \
    esac

[private]
schematic-id schematic:
    curl -sX POST --data-binary @"{{ source_directory() }}/schematics/{{ schematic }}.yaml" "https://factory.talos.dev/schematics" | jq -r '.id'
