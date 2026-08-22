set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l ansible

[private]
[script]
_playbook name:
    file="{{ source_directory() }}/playbooks/{{ name }}.yml"
    [[ -f "$file" ]] || { just log error "No such playbook" playbook "{{ name }}"; exit 1; }
    echo "$file"

[doc('Install the Galaxy collections pinned in requirements.yml')]
deps:
    ansible-galaxy collection install -r "{{ source_directory() }}/requirements.yml"

[doc('Dry run a playbook — --check --diff, changes nothing')]
check name *args:
    cd "{{ source_directory() }}" && op run --no-masking -- \
        ansible-playbook "$(just ansible _playbook {{ name }})" --check --diff {{ args }}

[confirm('Apply Ansible playbook ' + name + ' for real [y|N] ?')]
[doc('Run a playbook for real — dry run with `check` first')]
apply name *args:
    cd "{{ source_directory() }}" && op run --no-masking -- \
        ansible-playbook "$(just ansible _playbook {{ name }})" --diff {{ args }}

[doc('Lint every playbook and role')]
lint *args:
    cd "{{ source_directory() }}" && ansible-lint {{ args }}

[doc('Parse-check every playbook without connecting to anything')]
[script]
syntax-check:
    cd "{{ source_directory() }}"
    for f in playbooks/*.yml; do
        [[ -e "$f" ]] || continue
        just log info "Checking" playbook "$f"
        ansible-playbook "$f" --syntax-check
    done

[doc('Show the resolved inventory')]
inventory *args:
    cd "{{ source_directory() }}" && ansible-inventory --list {{ args }}

[doc('Gather facts from a host or group')]
facts pattern:
    cd "{{ source_directory() }}" && ansible '{{ pattern }}' -m ansible.builtin.setup

[doc('List available playbooks')]
[script]
playbooks:
    for f in "{{ source_directory() }}"/playbooks/*.yml; do
        [[ -e "$f" ]] || continue
        basename "$f" .yml
    done
