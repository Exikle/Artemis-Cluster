#!/usr/bin/env -S just --justfile

set minimum-version := '1.55.0'

set default-list
set default-script
set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# Agent tooling — opencode / Claude helpers
[group('AI')]
mod ai "ai"

# Ansible Recipes
[group('Ansible')]
mod ansible "ansible"

# Bootstrap Recipes
[group('Bootstrap')]
mod bootstrap "bootstrap"

# Kube Recipes
[group('Kube')]
mod kube "kubernetes"

# Talos Recipes
[group('Talos')]
mod talos "talos"

# OpenTofu Recipes
[group('Tofu')]
mod tofu "terraform"

# no-exit-message: `just log fatal` is a deliberate terminator, so just's own
# "recipe `log` failed" line on top of it is noise.
[no-exit-message]
[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template file *args:
    minijinja-cli "{{ file }}" {{ args }} | op inject
