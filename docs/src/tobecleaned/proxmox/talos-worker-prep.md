# Talos Machine Prep

brew install talosctl

brew install kubectl

brew install helm

brew install helmfile

brew install fluxcd/tap/flux

sops --decrypt {{.KUBERNETES_DIR}}/{{.cluster}}/bootstrap/talos/assets/{{.hostname}}.secret.sops.yaml | \
          envsubst | \
              talosctl --context {{.cluster}} apply-config --mode={{.mode}} --nodes {{.hostname}} --file /dev/stdin
sops --decrypt ~/Artemis-Cluster/kubernetes/flux/vars/cluster-secrets.secret.sops.yaml | kubectl apply --server-side --filename -

talosctl apply-config -f controlplane-thor.yaml -n 10.10.30.3 --insecure
talosctl apply-config -f controlplane-baldr.yaml -n 10.10.30.4 --insecure
