resource "routeros_system_ntp_client" "this" {
  enabled = true
  mode    = "unicast"
  servers = ["time.cloudflare.com"]
  vrf     = "main"
}

resource "routeros_interface_bridge" "bridge" {
  ageing_time         = "5m"
  arp                 = "enabled"
  arp_timeout         = "auto"
  auto_mac            = true
  dhcp_snooping       = false
  disabled            = false
  ether_type          = "0x8100"
  fast_forward        = true
  forward_delay       = "15s"
  frame_types         = "admit-all"
  igmp_snooping       = false
  ingress_filtering   = true
  max_learned_entries = "auto"
  max_message_age     = "20s"
  mtu                 = "auto"
  mvrp                = false
  name                = "bridge"
  port_cost_mode      = "long"
  priority            = "0x8000"
  protocol_mode       = "rstp"
  pvid                = 1
  transmit_hold_count = 6
  vlan_filtering      = true
}

resource "routeros_interface_bridge_port" "sfp7_atlas" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-all"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "sfp-sfpplus7"
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 1099
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

resource "routeros_interface_bridge_port" "sfp1_ucg" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-all"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "sfp-sfpplus1"
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 1
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

resource "routeros_interface_bridge_port" "sfp8_pantheon" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-all"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "sfp-sfpplus8"
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 1
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

resource "routeros_interface_bridge_port" "sfp2_uswitch48" {
  auto_isolate            = false
  bpdu_guard              = false
  bridge                  = "bridge"
  broadcast_flood         = true
  disabled                = false
  edge                    = "auto"
  fast_leave              = false
  frame_types             = "admit-all"
  horizon                 = "none"
  hw                      = true
  ingress_filtering       = true
  interface               = "sfp-sfpplus2"
  learn                   = "auto"
  multicast_router        = "temporary-query"
  mvrp_applicant_state    = "normal-participant"
  mvrp_registrar_state    = "normal"
  point_to_point          = "auto"
  priority                = "0x80"
  pvid                    = 1
  restricted_role         = false
  restricted_tcn          = false
  tag_stacking            = false
  trusted                 = false
  unknown_multicast_flood = true
  unknown_unicast_flood   = true
}

resource "routeros_system_identity" "this" {
  name = "Mikrotik-CRS309"
}

resource "routeros_interface_vlan" "lab" {
  arp                        = "enabled"
  arp_timeout                = "auto"
  disabled                   = false
  interface                  = "bridge"
  loop_protect               = "default"
  loop_protect_disable_time  = "5m"
  loop_protect_send_interval = "5s"
  mtu                        = "1500"
  mvrp                       = false
  name                       = "LAB"
  use_service_tag            = false
  vlan_id                    = 1099
}

resource "routeros_interface_vlan" "iot" {
  arp                        = "enabled"
  arp_timeout                = "auto"
  disabled                   = false
  interface                  = "bridge"
  loop_protect               = "default"
  loop_protect_disable_time  = "5m"
  loop_protect_send_interval = "5s"
  mtu                        = "1500"
  mvrp                       = false
  name                       = "IOT"
  use_service_tag            = false
  vlan_id                    = 1152
}

resource "routeros_ip_route" "default" {
  distance      = 1
  dst_address   = "0.0.0.0/0"
  gateway       = "10.10.99.1"
  routing_table = "main"
  scope         = 30
  target_scope  = 10
}

resource "routeros_interface_bridge_vlan" "trunk" {
  bridge         = "bridge"
  disabled       = false
  mvrp_forbidden = []
  tagged         = ["bridge", "sfp-sfpplus1", "sfp-sfpplus2", "sfp-sfpplus8"]
  untagged       = []
  vlan_ids       = ["1099", "1152"]
}

resource "routeros_interface_bridge_vlan" "passthrough" {
  bridge   = "bridge"
  disabled = false
  tagged   = ["sfp-sfpplus1", "sfp-sfpplus2", "sfp-sfpplus8"]
  untagged = []
  vlan_ids = ["1001", "1062", "1088", "1151"]
}

moved {
  from = routeros_interface_bridge_vlan.uplink_only
  to   = routeros_interface_bridge_vlan.passthrough
}
