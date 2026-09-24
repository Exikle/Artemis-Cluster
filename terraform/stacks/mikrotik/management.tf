# Management on LAB by DHCP, with a fixed IP set as a UniFi client reservation.
# The UCG hands out the address, DNS and default route like any other LAB device.
resource "routeros_ip_dhcp_client" "lab" {
  interface         = routeros_interface_vlan.lab.name
  add_default_route = "no"
  use_peer_dns      = true
  use_peer_ntp      = false
}
