set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

export TF_VAR_state_passphrase := 'op://kubernetes/tofu-state/PASSPHRASE'

[private]
default:
    just -l tofu

[private]
[script]
_stack-dir stack:
    dir="{{ source_directory() }}/stacks/{{ stack }}"
    [[ -d "$dir" ]] || { just log error "No such stack" stack "{{ stack }}"; exit 1; }
    echo "$dir"

[private]
[script]
_run stack *args:
    cd "$(just tofu _stack-dir {{ stack }})"
    op run --no-masking -- tofu {{ args }}

[doc('Initialise a stack (downloads providers, configures the backend)')]
init stack *args:
    just tofu _run "{{ stack }}" init {{ args }}

[doc('Show what a stack would change — always run this before apply')]
plan stack *args:
    just tofu _run "{{ stack }}" plan {{ args }}

[confirm('Apply OpenTofu changes to stack ' + stack + ' [y|N] ?')]
[doc('Apply a stack')]
apply stack *args:
    just tofu _run "{{ stack }}" apply {{ args }}

[doc('Import an existing object into state (address, then provider-specific id)')]
import stack address id:
    just tofu _run "{{ stack }}" import '{{ address }}' '{{ id }}'

[doc('Validate a stack')]
validate stack:
    just tofu _run "{{ stack }}" validate

[doc('Show the current state of a stack')]
show stack *args:
    just tofu _run "{{ stack }}" show {{ args }}

[doc('Format all OpenTofu files in place')]
fmt:
    tofu fmt -recursive "{{ source_directory() }}"

[doc('Check formatting without writing — used by CI')]
fmt-check:
    tofu fmt -recursive -check -diff "{{ source_directory() }}"

[doc('List available stacks')]
[script]
stacks:
    for d in "{{ source_directory() }}"/stacks/*/; do
        [[ -f "${d}main.tf" ]] || continue
        basename "$d"
    done
