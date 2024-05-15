commands to bootstrap flux whe i uninstall it

````
kubectl apply --server-side --kustomize ~/Artemis-Cluster/kubernetes/bootstrap/flux
# Install secrets and configmaps
- cd ~/.sops
- cat age.agekey |
kubectl create secret generic sops-age \
--namespace=flux-system \
--from-file=age.agekey=/dev/stdin
- sops --decrypt ~/Artemis-Cluster/kubernetes/bootstrap/fluxgithub.secret.sops.yaml | kubectl apply --server-side --filename -
- sops --decrypt ~/Artemis-Cluster/kubernetes/flux/vars/cluster-secrets.secret.sops.yaml | kubectl apply --server-side --filename -
- kubectl apply --server-side --filename ~/Artemis-Cluster/kubernetes/flux/vars/cluster-settings.yaml
- kubectl apply --server-side --kustomize ~/Artemis-Cluster/kubernetes/flux/config
````