# Cilium Install

````
brew install cilium-cli

helm repo add cilium https://helm.cilium.io/

helm install cilium cilium/cilium --version 1.15.5 \
   --namespace kube-system \
   --reuse-values \
   --set operator.replicas=1 \
   --set kubeProxyReplacement=true \
   --set l2announcements.enabled=true \
   --set k8sClientRateLimit.qps=32 \
   --set k8sClientRateLimit.burst=60 \
   --set kubeProxyReplacement=strict \
   --set k8sServiceHost=10.10.99.201 \
   --set k8sServicePort=6443 \
   --set gatewayAPI.enabled=true
````
