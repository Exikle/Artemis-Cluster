variable "cloudflare_dns_token" {
  type        = string
  description = "Cloudflare API token with DNS edit rights on dcunha.io. From 1Password via secrets.env."
  sensitive   = true
}

# wan.dcunha.io is otherwise a static A record pointing at the Rogers WAN
# address. When that address rotates the record goes stale silently — nothing
# alerts, it simply stops resolving to the right place. The gateway is the first
# thing that learns the new address, so it is the right thing to publish it.
resource "unifi_dynamic_dns" "wan" {
  service   = "cloudflare"
  host_name = "wan.dcunha.io"
  interface = "wan"
  login     = "dcunha.io"
  password  = var.cloudflare_dns_token
}
