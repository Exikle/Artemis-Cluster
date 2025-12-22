# Networking & Ingress Architecture

This document details the split-horizon DNS and Dual-Gateway ingress architecture for the Artemis Cluster.

## 1. Gateway Architecture

The cluster utilizes the **Cilium Gateway API** configured with two distinct Gateways to physically separate Internal and External traffic. This provides security isolation and simplifies configuration.

| Component | Resource Name | IP Address | Purpose |
| :--- | :--- | :--- | :--- |
| **External Gateway** | `external-gateway` | `10.10.99.97` | Handles public Internet traffic (`.io`). Secured via HTTPS/TLS. |
| **Internal Gateway** | `internal-gateway` | `10.10.99.98` | Handles home network traffic (`.lab`). HTTP Only. |

### Routing Logic

- **Global Target (External):** The `external-gateway` is annotated with `external-dns.alpha.kubernetes.io/target: "ingress.dcunha.io"`. All attached routes automatically generate `CNAME` records pointing to this stable DDNS hostname.
- **Native A-Record (Internal):** The `internal-gateway` has no target annotation. External-DNS auto-detects its IP (`10.10.99.98`) and creates direct `A` Records for all attached routes.

## 2. DNS Strategy

The cluster uses a split-horizon DNS approach managed by two instances of **External-DNS**.

### External DNS (`.io`)

- **Provider:** Cloudflare
- **Controller:** `external-dns-cloudflare`
- **Mechanism:** Creates `CNAME` records pointing to `ingress.dcunha.io`. The `ingress.dcunha.io` record itself is managed by the `cloudflare-ddns` container, which keeps it updated with the public WAN IP.
- **Wildcard Support:** A dummy HTTPRoute forces External-DNS to create a `*.dcunha.io` CNAME to handle fallback traffic.

### Internal DNS (`.lab`)

- **Provider:** Technitium (via RFC2136)
- **Controller:** `external-dns-technitium`
- **Mechanism:** Creates `A` records pointing directly to the internal gateway's IP, `10.10.99.98`.
- **Wildcard Support:** A manual wildcard `*` A-record exists in the Technitium DNS server pointing to `10.10.99.98` to handle fallback traffic.

## 3. Fallback & Error Handling

The cluster implements a catch-all routing strategy to prevent connection timeouts for undefined subdomains.

- **Mechanism:** The `error-pages` HelmRelease creates low-priority HTTPRoutes for `*.dcunha.io` and `*.dcunha.io`.
- **Behavior:**
    1. If a specific HTTPRoute exists (e.g., `plex.dcunha.io`), traffic is routed to the Plex service.
    2. If no specific route exists (e.g., `fake.dcunha.io`), the wildcard DNS directs traffic to the appropriate Gateway. The Gateway then matches the wildcard HTTPRoute and serves a custom 404 page from the `error-pages` service.

## 4. Deploying New Services

Use the following templates when adding `HTTPRoutes` via HelmRelease values or Kustomize configurations.

### Important Notes

1. **Namespace:** You must explicitly set `namespace: default` in the `parentRefs`, as the Gateways live in the `default` namespace.
2. **Annotations:** Annotations for External-DNS differ based on the target environment.

### Internal Service Template (`.lab`)

*For private apps like Longhorn, Headlamp.*

```
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-internal
  namespace: my-namespace
  annotations:
    # Required for the Technitium External-DNS to see this route
    external-dns.alpha.kubernetes.io/internal: "true"
    external-dns.alpha.kubernetes.io/hostname: "my-app.dcunha.io"
spec:
  parentRefs:
    - name: internal-gateway
      namespace: default
  hostnames:
    - "my-app.dcunha.io"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-app-service
          port: 80
```

### External Service Template (`.io`)

*For public apps like a blog or game server status page.*

```
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-external
  namespace: my-namespace
  annotations:
    external-dns.alpha.kubernetes.io/hostname: "my-app.dcunha.io"
    # Note: No target annotation is needed; it inherits from the Gateway.
spec:
  parentRefs:
    - name: external-gateway
      namespace: default
  hostnames:
    - "my-app.dcunha.io"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-app-service
          port: 80
```

## 5. Troubleshooting Flowchart

| Symptom | First Check | Next Step |
| :--- | :--- | :--- |
| **Timeout** on `.lab` or `.io` | `ping <gateway-ip>` (e.g., `10.10.99.98`) | If no reply, check `kubectl get gateway`. If reply, check DNS with `dig`. |
| **404 Ghost Page** on a valid app | `kubectl get httproute -A` | Check `parentRefs` for `namespace: default`. Check backend service name and port. |
| **Cloudflare 522/Timeout** | Firewall / Router NAT Rules | Ensure Port 443 is forwarded to `10.10.99.97`. Check Hairpin NAT for local testing. |
| **Cloudflare 500 Error** | Backend Service | The Gateway is working, but can't find the pod/service. Run `kubectl get pods,svc -n <app-namespace>`. |
| **DNS "Not Found"** | External-DNS Logs | Check logs for the relevant controller (`technitium` or `cloudflare`) for errors. |

```
