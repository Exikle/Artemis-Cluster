set default-list
set default-script
set no-exit-message
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Install the Galaxy collections pinned in requirements.yml')]
deps:
    ansible-galaxy collection install -r "{{ source_directory() }}/requirements.yml"

# op run wraps check and apply only: those run roles that resolve secrets with
# community.general.onepassword lookups, which shell out to an authenticated op.
[doc('Dry run a playbook — --check --diff, changes nothing')]
check name *args:
    op run --no-masking -- \
        ansible-playbook "$(just ansible _playbook {{ name }})" --check --diff {{ args }}

[confirm('Apply Ansible playbook ' + name + ' for real [y|N] ?')]
[doc('Run a playbook for real — dry run with `check` first')]
apply name *args:
    op run --no-masking -- \
        ansible-playbook "$(just ansible _playbook {{ name }})" --diff {{ args }}

[doc('Lint every playbook and role')]
lint *args:
    ansible-lint {{ args }}

[doc('Parse-check every playbook without connecting to anything')]
syntax-check:
    rc=0
    for f in "{{ source_directory() }}"/playbooks/*.yml; do
        [[ -e "$f" ]] || continue
        if ansible-playbook "$f" --syntax-check >/dev/null 2>&1; then
            just log info "Syntax valid" playbook "$(basename "$f" .yml)"
        else
            just log error "Syntax INVALID" playbook "$(basename "$f" .yml)"
            rc=1
        fi
    done
    exit "$rc"

[doc('Show the resolved inventory')]
inventory *args:
    ansible-inventory --list {{ args }}

[doc('Gather facts from a host or group')]
facts pattern:
    ansible '{{ pattern }}' -m ansible.builtin.setup

[doc('List available playbooks')]
playbooks:
    for f in "{{ source_directory() }}"/playbooks/*.yml; do
        [[ -e "$f" ]] || continue
        basename "$f" .yml
    done

[private]
_playbook name:
    file="{{ source_directory() }}/playbooks/{{ name }}.yml"
    [[ -f "$file" ]] || just log fatal "No such playbook" playbook "{{ name }}"
    echo "$file"
