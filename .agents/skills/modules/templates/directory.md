# Module: Directory Structure Template

Every app uses this canonical layout:

```
clusters/artemis/kubernetes/apps/<namespace>/<app>/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml
    └── helmrelease.yaml      ← secrets go inline under values.externalSecrets
```

After creating the directory, add `- ./<app>/ks.yaml` to `clusters/artemis/kubernetes/apps/<namespace>/kustomization.yaml` resources.

## Verify structure

```bash
find clusters/artemis/kubernetes/apps/<namespace>/<app> -type f | sort
```

Expected output (no ExternalSecret):

```
clusters/artemis/kubernetes/apps/<namespace>/<app>/app/helmrelease.yaml
clusters/artemis/kubernetes/apps/<namespace>/<app>/app/kustomization.yaml
clusters/artemis/kubernetes/apps/<namespace>/<app>/app/ocirepository.yaml
clusters/artemis/kubernetes/apps/<namespace>/<app>/ks.yaml
```
