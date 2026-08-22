# Adopted by import on 2026-08-22 from the live controller — not authored by hand.
# A bad apply here can sever the path it is applied over. Plan first, always.
#
# NOTE: dns_servers = ["10.10.99.3"] below is the DECOMMISSIONED Technitium VM
# (dead since 2026-05-04). It is inert — dns_enabled is false, so clients get the
# gateway — and it is recorded here only because the controller will not let go
# of it. Clearing it was attempted three ways and all failed: removing the
# attribute, setting it to [], and a full-object API PUT with the dhcpd_dns_*
# keys removed (which returns rc:ok and changes nothing — UniFi treats an absent
# key as "unchanged"). It has to be cleared in the UI.
#
# The risk it carries: if anyone ever enables custom DNS on one of these networks
# in the UI, every client on that VLAN gets a resolver that has been dead since
# May. Clear the field first if that is ever wanted.
# __generated__ by OpenTofu from "69d02d79cefe6560e6b42e9f"
resource "unifi_network" "iot" {
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
    leasetime           = "24h0m0s"
    ntp_enabled         = false
    start               = "10.10.152.50"
    stop                = "10.10.152.200"
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
  ipv6_client_address_assignment = "slaac"
  ipv6_interface_type            = "pd"
  ipv6_pd_auto_prefixid_enabled  = true
  ipv6_pd_interface              = "wan"
  ipv6_pd_prefixid               = null
  ipv6_pd_start                  = "::2"
  ipv6_pd_stop                   = "::7d1"
  ipv6_ra                        = true
  ipv6_ra_preferred_lifetime     = null
  ipv6_ra_priority               = "high"
  ipv6_ra_valid_lifetime         = null
  ipv6_static_subnet             = null
  lte_lan                        = true
  multicast_dns                  = true
  name                           = "IOT"
  network_isolation              = false
  purpose                        = "corporate"
  setting_preference             = "manual"
  site                           = "default"
  subnet                         = "10.10.152.1/24"
  third_party_gateway            = false
  vlan                           = 1152
}

resource "unifi_network" "transit" {
  auto_scale                     = false
  dhcp_v6_server                 = null
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
  name                           = "TRANSIT"
  network_isolation              = false
  purpose                        = "corporate"
  setting_preference             = "manual"
  site                           = "default"
  subnet                         = "172.16.99.1/30"
  third_party_gateway            = false
  vlan                           = 99
}

# __generated__ by OpenTofu from "69d03195cefe6560e6b42f40"
resource "unifi_network" "hme" {
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
    leasetime           = "24h0m0s"
    ntp_enabled         = false
    start               = "10.10.1.50"
    stop                = "10.10.1.200"
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
  name                           = "HME"
  network_isolation              = false
  purpose                        = "corporate"
  setting_preference             = "manual"
  site                           = "default"
  subnet                         = "10.10.1.1/24"
  third_party_gateway            = false
  vlan                           = 1001
}

# __generated__ by OpenTofu from "6955bb732442f037b9b78fdc"
resource "unifi_network" "lan" {
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
    leasetime           = "24h0m0s"
    ntp_enabled         = false
    start               = "192.168.1.50"
    stop                = "192.168.1.200"
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
  ipv6_client_address_assignment = "slaac"
  ipv6_interface_type            = "none"
  ipv6_pd_auto_prefixid_enabled  = false
  ipv6_pd_interface              = null
  ipv6_pd_prefixid               = null
  ipv6_pd_start                  = "::2"
  ipv6_pd_stop                   = "::7d1"
  ipv6_ra                        = true
  ipv6_ra_preferred_lifetime     = "4h0m0s"
  ipv6_ra_priority               = "high"
  ipv6_ra_valid_lifetime         = null
  ipv6_static_subnet             = null
  lte_lan                        = true
  multicast_dns                  = true
  name                           = "LAN"
  network_isolation              = false
  purpose                        = "corporate"
  setting_preference             = "manual"
  site                           = "default"
  subnet                         = "192.168.1.1/24"
  third_party_gateway            = false
}

# __generated__ by OpenTofu from "69d02c5acefe6560e6b42e86"
resource "unifi_network" "gst" {
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
    leasetime           = "8h0m0s"
    ntp_enabled         = false
    start               = "10.10.151.50"
    stop                = "10.10.151.200"
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
  name                           = "GST"
  network_isolation              = false
  purpose                        = "corporate"
  setting_preference             = "manual"
  site                           = "default"
  subnet                         = "10.10.151.1/24"
  third_party_gateway            = false
  vlan                           = 1151
}

# __generated__ by OpenTofu from "69d034c5cefe6560e6b42fb8"
resource "unifi_network" "lab" {
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
    leasetime           = "24h0m0s"
    ntp_enabled         = false
    start               = "10.10.99.50"
    stop                = "10.10.99.70"
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
  ipv6_client_address_assignment = "slaac"
  ipv6_interface_type            = "pd"
  ipv6_pd_auto_prefixid_enabled  = true
  ipv6_pd_interface              = "wan"
  ipv6_pd_prefixid               = null
  ipv6_pd_start                  = "::2"
  ipv6_pd_stop                   = "::7d1"
  ipv6_ra                        = true
  ipv6_ra_preferred_lifetime     = null
  ipv6_ra_priority               = "high"
  ipv6_ra_valid_lifetime         = null
  ipv6_static_subnet             = null
  lte_lan                        = true
  multicast_dns                  = true
  name                           = "LAB"
  network_isolation              = false
  purpose                        = "corporate"
  setting_preference             = "manual"
  site                           = "default"
  subnet                         = "10.10.99.1/24"
  third_party_gateway            = false
  vlan                           = 1099
}
