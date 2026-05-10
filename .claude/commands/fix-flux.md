Diagnose and fix Flux reconciliation issues in the Artemis-Cluster.

## Step 1 — Identify what's broken

Run a health check across all Flux resources:

```bash
flux get all -A --status-selector ready=false
kubectl get helmrelease -A | grep -v "True"
kubectl get kustomization -A | grep -v "True"
```

Ask the user which specific app/namespace is having issues if not already known.

## Step 2 — Diagnose by symptom

### Stuck HelmRelease (install/upgrade retrying)

```bash
flux describe helmrelease <app> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

Fix:

```bash
flux suspend helmrelease <app> -n <namespace>
kubectl delete secret -n <namespace> -l name=<app>,owner=helm
flux resume helmrelease <app> -n <namespace>
```

### Kustomization not reconciling

```bash
flux describe kustomization <namespace>-<app> -n flux-system
```

Common causes:

- `dependsOn` target doesn't exist or isn't Ready — check dependency chain
- Schema validation error — run `PATH="$HOME/.local/share/mise/shims:$PATH" flux-local test kubernetes/apps/<namespace>/<app>/app`
- Git source not synced — `flux reconcile source git flux-system`

### ExternalSecret not syncing / pod has empty secret

```bash
kubectl describe externalsecret <app> -n <namespace>
just kube sync-es
kubectl get secret <app> -n <namespace> -o yaml
```

Common causes:

- 1Password field name mismatch — check exact field names in 1Password match the template `{{ .FIELD_NAME }}`
- onepassword-connect pod unhealthy — `kubectl get pods -n external-secrets`

### Pod stuck in ContainerCreating (RBD CSI issue)

```bash
kubectl describe pod <pod> -n <namespace> | grep -A5 Events
```

If you see `rpc error` or `volume attachment`:

```bash
# 1. Restart the CSI node plugin on the affected node
kubectl delete pod -n rook-ceph -l app=csi-rbdplugin --field-selector spec.nodeName=<node>
# 2. Clean stale VolumeAttachments
kubectl get volumeattachment | grep <node>
kubectl delete volumeattachment <name>
# 3. If still stuck — reboot the node
talosctl reboot -n <node-ip> --wait
```

### Image pull errors

```bash
kubectl describe pod <pod> -n <namespace> | grep -A3 "Failed"
```

- Verify image tag exists in the registry
- If rate limited: wait or check if imagePullSecret is needed

### HelmRelease values not applying after git change

```bash
flux reconcile helmrelease <app> -n <namespace> --with-source
```

## Step 3 — Force full reconciliation if needed

```bash
# Sync git source first
PATH="$HOME/.local/share/mise/shims:$PATH" just kube sync-git

# Then force specific resources
flux reconcile kustomization <namespace>-<app> -n flux-system --with-source
flux reconcile helmrelease <app> -n <namespace>
```

## Step 4 — Verify resolution

```bash
flux get helmrelease <app> -n <namespace>
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl logs -n <namespace> deployment/<app> --tail=20
```

## Nuclear option — full namespace reconcile

Only if multiple apps in a namespace are broken:

```bash
flux reconcile kustomization <namespace> -n flux-system --with-source
```
