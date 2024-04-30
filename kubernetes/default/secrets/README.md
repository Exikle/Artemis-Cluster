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