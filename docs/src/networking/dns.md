# DNS & Split-Horizon

The cluster uses split-horizon DNS so that services resolve to internal IPs from inside the home network and are accessible externally via Cloudflare.

---

## Architecture

```
External clients
  └── Cloudflare DNS (proxied) → Cloudflare Tunnel → external-gateway pod (10.10.99.97)

Internal clients (HME, LAN, LAB)
  └── UCG-Max DNS → internal A record → internal-gateway (10.10.99.98)
                                       OR
                  → external A record → external-gateway (10.10.99.97)
```

---

## UCG-Max DNS

The UCG-Max acts as the recursive DNS resolver for all VLANs. It is configured with:

- **Split-horizon domain:** `dcunha.io` — internal A records override Cloudflare for this domain
- **Upstream forwarders:** Cloudflare (`1.1.1.1`, `1.0.0.1`)

Two ExternalDNS instances write records automatically:

| Controller                | Provider                   | Watches                       | Writes                                |
| ------------------------- | -------------------------- | ----------------------------- | ------------------------------------- |
| `external-dns-unifi`      | UCG-Max webhook (kashalls) | `internal-gateway` HTTPRoutes | A records → 10.10.99.98               |
| `external-dns-cloudflare` | Cloudflare API             | `external-gateway` HTTPRoutes | CNAME → `external.dcunha.io`, proxied |

---

## Two Gateways

| Gateway            | IP          | Purpose                                                 |
| ------------------ | ----------- | ------------------------------------------------------- |
| `external-gateway` | 10.10.99.97 | Internet-facing services, Cloudflare Tunnel entry point |
| `internal-gateway` | 10.10.99.98 | LAN-only services (Grafana, Prometheus, etc.)           |

The gateways are annotated with `external-dns.alpha.kubernetes.io/target`:

- `external-gateway` → target `external.dcunha.io` — Cloudflare DNS record + `lbipam.cilium.io/ips: 10.10.99.97`
- `internal-gateway` → target `internal.dcunha.io` — UCG-Max DNS record + `lbipam.cilium.io/ips: 10.10.99.98`

---

## Cloudflare Tunnel

External traffic flows through Cloudflare Zero Trust Network Access rather than a port-forwarded IP:

1. Cloudflare receives a request for `*.dcunha.io`
2. The tunnel routes it to the `cloudflare-tunnel` pod (2 replicas, PodDisruptionBudget min 1)
3. The pod forwards directly to `https://external-gateway.network.svc.cluster.local:443`
4. Envoy routes to the matching HTTPRoute

The tunnel bypasses the external gateway's LoadBalancer IP entirely for inbound public traffic. The `external-gateway` IP (10.10.99.97) is still used for internal split-horizon access to externally-annotated services.

**Tunnel config** (`kubernetes/apps/network/cloudflare-tunnel/app/helmrelease.yaml`):

```yaml
ingress:
    - hostname: "*.dcunha.io"
      originRequest:
          http2Origin: true
          originServerName: external.dcunha.io
      service: https://external-gateway.network.svc.cluster.local:443
    - service: http_status:404
```

---

## Deploying a New Service

### Internal only (LAN-accessible, no internet)

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
              - name: my-app
                port: 8080
```

`external-dns-unifi` auto-detects this and writes `my-app.dcunha.io → 10.10.99.98` to UCG-Max DNS.

### External (internet-accessible via Cloudflare Tunnel)

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
              - name: my-app
                port: 8080
```

`external-dns-cloudflare` auto-detects this and writes a proxied CNAME in Cloudflare.

---

## Troubleshooting

| Symptom                                    | Check                                                                                   |
| ------------------------------------------ | --------------------------------------------------------------------------------------- |
| Name not resolving from home network       | `dig my-app.dcunha.io @10.10.99.1` — check UCG-Max has the A record                     |
| Name not resolving externally              | Check Cloudflare DNS dashboard for the CNAME record                                     |
| `kubectl get httproute -A` shows no routes | Check the `parentRefs` gateway name and namespace                                       |
| ExternalDNS not writing records            | `kubectl logs -n network deploy/external-dns-unifi` or `deploy/external-dns-cloudflare` |
