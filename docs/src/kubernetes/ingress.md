# Ingress & Gateways

The cluster uses [Envoy Gateway](https://gateway.envoyproxy.io/) (Gateway API) for all ingress, with [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) for external access and ExternalDNS for automatic DNS record management.

See [DNS & Split-Horizon](../networking/dns.md) for the full DNS flow.

---

## Gateways

Two Gateway objects are defined in `kubernetes/apps/network/envoy-gateway/app/envoy.yaml`:

| Gateway            | IP          | Listeners            | Purpose                                          |
| ------------------ | ----------- | -------------------- | ------------------------------------------------ |
| `external-gateway` | 10.10.99.97 | HTTP :80, HTTPS :443 | Internet-facing services (via Cloudflare Tunnel) |
| `internal-gateway` | 10.10.99.98 | HTTP :80, HTTPS :443 | LAN-only services                                |

Both gateways share the same wildcard TLS certificate (`dcunha-io-tls` Secret in `network` namespace). HTTP traffic on port 80 is redirected to HTTPS via an `https-redirect` HTTPRoute.

---

## Envoy Deployment

The `EnvoyProxy` resource configures the backing Envoy deployment:

- **Replicas:** 2
- **PodDisruptionBudget:** 1 minimum available
- **Compression:** Zstd, Brotli, Gzip (backend), with HTTP/2 and HTTP/3 support
- **TLS minimum version:** 1.2, ALPN: `h2`, `http/1.1`
- **Drain timeout:** 180 s
- **Metrics:** Prometheus endpoint (gzip compressed)

---

## Cloudflare Tunnel

The `cloudflare-tunnel` deployment (2 replicas) connects to Cloudflare's network and forwards `*.dcunha.io` traffic directly to the `external-gateway` pod:

```yaml
ingress:
    - hostname: "*.dcunha.io"
      originRequest:
          http2Origin: true
          originServerName: external.dcunha.io
      service: https://external-gateway.network.svc.cluster.local:443
    - service: http_status:404
```

The tunnel **bypasses the LoadBalancer IP** — traffic comes in through Cloudflare's edge and is injected directly into the pod, which hands it to Envoy. The external-gateway IP (10.10.99.97) is only used for internal split-horizon access.

---

## ExternalDNS

Two ExternalDNS instances watch different gateways and write to different DNS providers:

| Instance                  | Watches                       | Writes to                                                 |
| ------------------------- | ----------------------------- | --------------------------------------------------------- |
| `external-dns-cloudflare` | `external-gateway` HTTPRoutes | Cloudflare DNS (proxied CNAME → `external.dcunha.io`)     |
| `external-dns-unifi`      | `internal-gateway` HTTPRoutes | UCG-Max DNS via kashalls webhook (A record → 10.10.99.98) |

TXT ownership records are prefixed with `k8s.` in both cases. `external-dns-cloudflare` uses `txtOwnerId: artemis-cluster`, `external-dns-unifi` uses `txtOwnerId: k8s-internal`.

---

## Certificates

A single wildcard certificate covers all services:

- **Cert:** `dcunha-io-tls` (Secret in `network` namespace)
- **Issuer:** Let's Encrypt production via cert-manager
- **DNS names:** `dcunha.io`, `*.dcunha.io`

The certificate is issued by cert-manager and referenced by both gateways. See [Certificates](certificates.md).

---

## Adding a New HTTPRoute

### Internal service

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
    name: my-app
    namespace: my-namespace
spec:
    parentRefs:
        - name: internal-gateway
          namespace: network
    hostnames:
        - my-app.dcunha.io
    rules:
        - matches:
              - path:
                    type: PathPrefix
                    value: /
          backendRefs:
              - name: my-app-svc
                port: 8080
```

### External service (internet-accessible)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
    name: my-app
    namespace: my-namespace
spec:
    parentRefs:
        - name: external-gateway
          namespace: network
    hostnames:
        - my-app.dcunha.io
    rules:
        - matches:
              - path:
                    type: PathPrefix
                    value: /
          backendRefs:
              - name: my-app-svc
                port: 8080
```

---

## Troubleshooting

```bash
# Check gateway status
kubectl get gateway -n network

# List all HTTPRoutes
kubectl get httproute -A

# Check Envoy proxy pods
kubectl get pods -n network -l gateway.envoyproxy.io/owning-gateway-name

# Check ExternalDNS logs
kubectl logs -n network deploy/external-dns-cloudflare
kubectl logs -n network deploy/external-dns-unifi

# Check tunnel connectivity
kubectl logs -n network deploy/cloudflare-tunnel
```
