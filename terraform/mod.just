set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# 1Password reference for the state-encryption passphrase. Read at run time and
# injected as TF_ENCRYPTION — never written to a file, never in a provider block.
passphrase_ref := env('TOFU_PASSPHRASE_REF', 'op://kubernetes/tofu-state/password')

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
    dir="$(just tofu _stack-dir {{ stack }})"
    if [[ -n "${TOFU_PASSPHRASE:-}" ]]; then
        passphrase="$TOFU_PASSPHRASE"
    else
        passphrase="$(op read "{{ passphrase_ref }}")"
    fi
    if (( ${#passphrase} < 16 )); then
        just log error "State passphrase is missing or shorter than 16 characters" ref "{{ passphrase_ref }}"
        exit 1
    fi
    export TF_ENCRYPTION
    TF_ENCRYPTION="$(printf 'key_provider "pbkdf2" "main" {\n  passphrase = "%s"\n}\nmethod "aes_gcm" "main" {\n  keys = key_provider.pbkdf2.main\n}\nstate {\n  method = method.aes_gcm.main\n}\nplan {\n  method = method.aes_gcm.main\n}\n' "$passphrase")"
    unset passphrase
    cd "$dir"
    # A stack may declare provider credentials as 1Password references in
    # secrets.env. The file holds op:// refs only — never values — so it is
    # committed like the .j2 templates elsewhere in this repo.
    if [[ -f secrets.env ]]; then
        op run --no-masking --env-file=secrets.env -- tofu {{ args }}
    else
        tofu {{ args }}
    fi

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
