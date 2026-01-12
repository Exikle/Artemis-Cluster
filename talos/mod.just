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

# get-controller:
#     echo This is my Talos controller IP: {{ controller }}

# [doc('Apply Talos config to control plane 1')]
# apply-control-01:
#     talosctl apply-config -n 10.10.99.101 --file {{talos_dir}}/clusterconfig/artemis-cluster-talos-cp-01.yaml --mode=auto

# [doc('Apply Talos config to control plane 2')]
# apply-control-02:
#     talosctl apply-config -n 10.10.99.102 --file {{talos_dir}}/clusterconfig/artemis-cluster-talos-cp-02.yaml --mode=auto

# [doc('Apply Talos config to control plane 3')]
# apply-control-03:
#     talosctl apply-config -n 10.10.99.103 --file {{talos_dir}}/clusterconfig/artemis-cluster-talos-cp-03.yaml --mode=auto

# [doc('Apply Talos config to worker 1')]
# apply-worker-01:
#     talosctl apply-config -n 10.10.99.201 --file {{talos_dir}}/clusterconfig/artemis-cluster-talos-w-01.yaml --mode=auto

# [doc('Apply Talos config to worker 2')]
# apply-worker-02:
#     talosctl apply-config -n 10.10.99.202 --file {{talos_dir}}/clusterconfig/artemis-cluster-talos-w-02.yaml --mode=auto

# [doc('Apply Talos config to worker 3')]
# apply-worker-03:
#     talosctl apply-config -n 10.10.99.203 --file {{talos_dir}}/clusterconfig/artemis-cluster-talos-w-03.yaml --mode=auto

# [doc('Apply Talos config to all nodes')]
# apply-all:
#     just talos apply-control-01
#     just talos apply-control-02
#     just talos apply-control-03
#     just talos apply-worker-01
#     just talos apply-worker-02
#     just talos apply-worker-03

[doc('Apply Talos config to a node')]
apply-node node *args:
    talosctl apply-config -n {{node}} --file {{talos_dir}}/clusterconfig/artemis-cluster-{{node}}.yaml {{args}}

[doc('Retrieve kubeconfig from Talos cluster')]
retreive-kubeconfig *args:
      - talosctl kubeconfig --nodes {{ controller }} {{ args }}

[doc('Check Talos cluster health')]
check-cluster-health:
      - talosctl health --nodes {{ controller }}

[doc('Open Talos dashboard')]
open-dashboard:
      - talosctl dashboard --nodes {{ controller }}
