set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

scripts_dir := justfile_dir() + '/scripts'
talos_dir := justfile_dir() + '/talos'
controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`

[private]
default:
    just -l talos

[doc('Generate Talos machine configs using talhelper')]
genconfig:
    talhelper genconfig --secret-file talsecret.secret.sops.yaml
