# FluxCD Bootstrap

Commands to bootstrap and install flux

---
### Bootstrap Commands

````
brew install fluxcd/tap/flux
````

````
kubectl apply --server-side --kustomize ~/Artemis-Cluster/kubernetes/bootstrap/flux
````

````
# Install age.key secret
cd ~/.sops
cat age.agekey |
kubectl create secret generic sops-age \
--namespace=flux-system \
--from-file=age.agekey=/dev/stdin
````

````
# Install github and cluster secrets
sops --decrypt ~/Artemis-Cluster/kubernetes/bootstrap/flux/github.secret.sops.yaml | kubectl apply --server-side --filename -
sops --decrypt ~/Artemis-Cluster/kubernetes/flux/vars/cluster-secrets.secret.sops.yaml | kubectl apply --server-side --filename -
````

````
#Install kustomizations for the cluster
kubectl apply --server-side --filename ~/Artemis-Cluster/kubernetes/flux/vars/cluster-settings.yaml
kubectl apply --server-side --kustomize ~/Artemis-Cluster/kubernetes/flux/config
````

---

### Taskfile

Boostrap from scratch and will do all the following boostrap commands:
````
task flux:boostrap
`````

Install Fluxctl:

````
task flux:boostrap-fluxctl
`````

Create all secrets:
````
task flux:bootstrap-createagesecrets
````

Apply all repos:
````
task flux:bootstrap-applyrepos:
````