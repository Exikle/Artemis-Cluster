# Certificates

TLS certificates are managed by [cert-manager](https://cert-manager.io/) using Let's Encrypt with DNS-01 challenge via Cloudflare.

---

## Wildcard Certificate

A single wildcard certificate covers all services in the cluster:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
    name: dcunha-io
    namespace: network
spec:
    secretName: dcunha-io-tls
    issuerRef:
        name: letsencrypt-production
        kind: ClusterIssuer
    dnsNames:
        - dcunha.io
        - "*.dcunha.io"
```

The resulting Secret `dcunha-io-tls` in the `network` namespace is referenced by both Envoy gateways (`external-gateway` and `internal-gateway`).

---

## Certificate Export (Reflector)

The `network/certificates` kustomization handles syncing the wildcard cert to other namespaces via [Reflector](https://github.com/emberstack/kubernetes-reflector). The certificate is also exported to 1Password via a `PushSecret` for use outside the cluster (e.g. UCG-Max TLS).

---

## cert-manager

Deployed in the `cert-manager` namespace via Helm. Bootstrapped early in the helmfile chain (before ESO/1Password).

```bash
# Check certificate status
kubectl get certificates -A
kubectl describe certificate dcunha-io -n network

# Check cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager

# Force certificate renewal
kubectl delete secret dcunha-io-tls -n network
# cert-manager will automatically re-issue
```

---

## Reflector

[Reflector](https://github.com/emberstack/kubernetes-reflector) (`kube-system` namespace) mirrors Secrets and ConfigMaps across namespaces. Used to replicate `dcunha-io-tls` to namespaces that need TLS.

Annotate a Secret to enable reflection:

```yaml
metadata:
    annotations:
        reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
        reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
        reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "media,home-automation"
```
