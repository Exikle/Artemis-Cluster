https://artifacthub.io/packages/helm/bitwarden-secrets-manager-eso/bwsm-eso-provider

1. add repo
2. create name space - external-secrets
3. install bwsm eso to create connection to bitwarden
    - get secret manager token for service acc
create cluster secret store
- only proceed once its valid and ready?


https://technotim.live/posts/secret-encryption-sops/

https://major.io/p/encrypted-gitops-secrets-with-flux-and-age/

flux bootstrap github \
  --components-extra=image-reflector-controller,image-automation-controller \
  --owner=Exikle \
  --repository=Artemis-Cluster \
  --branch=master \
  --personal=true \
  --private=false \
  --path=kubernetes

  flux create kustomization my-secrets \
--source=my-secrets \
--path=./infrastructure/secrets \
--prune=true \
--interval=10m \
--decryption-provider=sops \
--decryption-secret=sops-age

install crds from eso
run helm chart for bwsm-eso
install secrets
dsadasdasda