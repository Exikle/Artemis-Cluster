#!/usr/bin/env -S just --justfile

set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

mod bootstrap "bootstrap"
mod kube "kubernetes"
mod talos "talos"

[private]
default:
    just -l

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

# [private] # !!! TODO learn makeninja stuff oneday
# template file *args:

[doc('Verify cluster state locally (Pre-commit check)')]
verify:
    just kube::test
    just kube::diff
