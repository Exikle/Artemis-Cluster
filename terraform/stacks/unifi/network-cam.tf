# Adopted by import on 2026-09-23 from the live controller — not authored by hand.
# A bad apply here can sever the path it is applied over. Plan first, always.
# CAM has no domain name on the controller; the generated `domain_name = ""` fails provider
# validation, so the attribute is left unset.
resource "unifi_network" "cam" {
  auto_scale = false
  dhcp_server = {
    boot = {
      enabled = false
    }
    conflict_checking   = true
    dns_enabled         = false
    enabled             = true
    gateway_enabled     = false
    leasetime           = "24h0m0s"
    ntp_enabled         = false
    start               = "10.10.62.50"
    stop                = "10.10.62.200"
    time_offset_enabled = false
    wins = {
      enabled = false
    }
  }
  enabled                       = true
  gateway_type                  = "default"
  igmp_snooping                 = false
  internet_access               = true
  ipv6_interface_type           = "none"
  ipv6_pd_auto_prefixid_enabled = false
  ipv6_ra                       = false
  lte_lan                       = true
  multicast_dns                 = true
  name                          = "CAM"
  network_isolation             = false
  purpose                       = "corporate"
  setting_preference            = "manual"
  site                          = "default"
  subnet                        = "10.10.62.1/24"
  third_party_gateway           = false
  vlan                          = 1062
}
