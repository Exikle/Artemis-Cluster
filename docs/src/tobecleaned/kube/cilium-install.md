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

helm upgrade cilium cilium/cilium --version 1.18.3 \
   --namespace kube-system \
   --reset-values \
   --set autoDirectNodeRoutes=true \
   --set bandwidthManager.enabled=true \
   --set bandwidthManager.bbr=true \
   --set bpf.masquerade=true \
   --set bpf.tproxy=true \
   --set cgroup.automount.enabled=false \
   --set cgroup.hostRoot=/sys/fs/cgroup \
   --set cluster.id=1 \
   --set cluster.name=main \
   --set devices=eth+ \
   --set enableRuntimeDeviceDetection=true \
   --set endpointRoutes.enabled=true \
   --set hubble.enabled=true \
   --set ipam.mode=kubernetes \
   --set ipv4NativeRoutingCIDR=10.42.0.0/16 \
   --set k8sServiceHost=localhost \
   --set k8sServicePort=7445 \
   --set kubeProxyReplacement=strict \
   --set kubeProxyReplacementHealthzBindAddr=0.0.0.0:10256 \
   --set l2announcements.enabled=true \
   --set bgpControlPlane.enabled=true \
   --set gatewayAPI.enabled=true \
   --set loadBalancer.algorithm=maglev \
   --set loadBalancer.mode=dsr \
   --set localRedirectPolicy=true \
   --set ingressController.enabled=true \
   --set operator.rollOutPods=true \
   --set operator.replicas=1 \
   --set rollOutCiliumPods=true \
   --set routingMode=native \
   --set k8sClientRateLimit.qps=32 \
   --set k8sClientRateLimit.burst=60

````
