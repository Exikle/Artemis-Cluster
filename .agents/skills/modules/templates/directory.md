# Module: Directory Structure Template

Every app follows this canonical layout:

```
kubernetes/apps/<namespace>/<app>/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml
    ├── helmrelease.yaml
    └── externalsecret.yaml   ← only if secrets needed
```

After creating the directory, add `- ./<app>/ks.yaml` to `kubernetes/apps/<namespace>/kustomization.yaml` resources.

## Verify structure

```bash
find kubernetes/apps/<namespace>/<app> -type f | sort
```

Expected output (no ExternalSecret):

```
kubernetes/apps/<namespace>/<app>/app/helmrelease.yaml
kubernetes/apps/<namespace>/<app>/app/kustomization.yaml
kubernetes/apps/<namespace>/<app>/app/ocirepository.yaml
kubernetes/apps/<namespace>/<app>/ks.yaml
```
