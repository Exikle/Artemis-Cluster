# Adopted by import on 2026-08-22 from the live controller — not authored by hand.
# A bad apply here can sever the path it is applied over. Plan first, always.
# __generated__ by OpenTofu from "69cfc94fcefe6560e6b42750"
resource "unifi_network" "tst" {
  auto_scale = false
  dhcp_server = {
    boot = {
      enabled = false
    }
    conflict_checking   = true
    dns_enabled         = false
    dns_servers         = ["10.10.99.3"]
    enabled             = true
    gateway_enabled     = false
    leasetime           = "12h0m0s"
    ntp_enabled         = false
    start               = "192.168.88.50"
    stop                = "192.168.88.200"
    time_offset_enabled = false
    wins = {
      enabled = false
    }
  }
  dhcp_v6_server                 = null
  domain_name                    = "dcunha.io"
  enabled                        = true
  gateway_type                   = "default"
  igmp_snooping                  = false
  internet_access                = true
  ipv6_aliases                   = null
  ipv6_client_address_assignment = null
  ipv6_interface_type            = "none"
  ipv6_pd_auto_prefixid_enabled  = false
  ipv6_pd_interface              = null
  ipv6_pd_prefixid               = null
  ipv6_pd_start                  = null
  ipv6_pd_stop                   = null
  ipv6_ra                        = false
  ipv6_ra_preferred_lifetime     = null
  ipv6_ra_priority               = null
  ipv6_ra_valid_lifetime         = null
  ipv6_static_subnet             = null
  lte_lan                        = true
  multicast_dns                  = true
  name                           = "TST"
  network_isolation              = false
  purpose                        = "corporate"
  setting_preference             = "manual"
  site                           = "default"
  subnet                         = "192.168.88.1/24"
  third_party_gateway            = false
  vlan                           = 1088
}
