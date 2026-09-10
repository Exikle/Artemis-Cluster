set default-list
set default-script
set no-exit-message
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# State-encryption passphrase. Read at run time into TF_ENCRYPTION — never written to
# a file, never through a provider.
passphrase_ref := env('TOFU_PASSPHRASE_REF', 'op://infrastructure/tofu-state/password')

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
stacks:
    for d in "{{ source_directory() }}"/stacks/*/; do
        [[ -f "${d}main.tf" ]] || continue
        basename "$d"
    done

[private]
_stack-dir stack:
    dir="{{ source_directory() }}/stacks/{{ stack }}"
    [[ -d "$dir" ]] || just log fatal "No such stack" stack "{{ stack }}"
    echo "$dir"

[private]
_run stack *args:
    dir="$(just tofu _stack-dir {{ stack }})"
    passphrase="${TOFU_PASSPHRASE:-$(op read "{{ passphrase_ref }}")}"
    (( ${#passphrase} >= 16 )) \
        || just log fatal "State passphrase missing or under 16 characters" ref "{{ passphrase_ref }}"

    # Escape before interpolating: a passphrase holding " \ ${ or %{ builds a broken
    # encryption block, and it fails as a parse error rather than a wrong key.
    esc="${passphrase//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    esc="${esc//'${'/'$${'}"
    esc="${esc//'%{'/'%%{'}"
    unset passphrase

    export TF_ENCRYPTION
    TF_ENCRYPTION="$(printf 'key_provider "pbkdf2" "main" {\n  passphrase = "%s"\n}\nmethod "aes_gcm" "main" {\n  keys = key_provider.pbkdf2.main\n}\nstate {\n  method = method.aes_gcm.main\n}\nplan {\n  method = method.aes_gcm.main\n}\n' "$esc")"

    cd "$dir"
    # secrets.env holds op:// refs only, never values, so it is committed.
    if [[ -f secrets.env ]]; then
        op run --no-masking --env-file=secrets.env -- tofu {{ args }}
    else
        tofu {{ args }}
    fi
