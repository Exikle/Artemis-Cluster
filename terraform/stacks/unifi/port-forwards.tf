# Adopted by import on 2026-09-23 from the live controller — not authored by hand.
# The only port forward on the UCG, kept deliberately for qBittorrent peer connectivity;
# it lands on the `bittorrent` LoadBalancer IP. See media-stack.md § qBittorrent.
resource "unifi_port_forward" "qbittorrent" {
  forward = {
    ip   = "10.10.99.95"
    port = "31288"
  }
  logging  = false
  name     = "qBittorrent"
  protocol = "tcp_udp"
  site     = "default"
  wan = {
    interface  = "wan"
    ip_address = "any"
    port       = "31288"
  }
}
