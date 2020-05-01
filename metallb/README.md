https://metallb.universe.tf/installation/

kubectl apply -f namespace.yaml

kubectl apply -f metallb.yaml

# On first install only
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"

apply layer2-config.yaml
