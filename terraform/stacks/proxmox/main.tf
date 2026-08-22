# This stack is adopted, never authored: every resource here was imported from a
# guest that already existed, and `tofu plan` must report no changes.
#
# LXC 105 (forgejo) is deliberately NOT managed here. The provider requires
# `template_file_id` on a container, that value cannot be read back from a running
# guest, and the original template no longer exists on pantheon — so any value
# would be invented. The attribute is ForceNew, so an invented value plans a
# replacement, i.e. destroys Forgejo. The container is configured by the Ansible
# layer instead, which is the right owner for something that already exists.
data "proxmox_virtual_environment_nodes" "available" {}

data "proxmox_virtual_environment_vms" "all" {}

output "nodes" {
  description = "Node names pantheon reports — proves the API token authenticates."
  value       = data.proxmox_virtual_environment_nodes.available.names
}

output "inventory" {
  description = "Existing guests, so imports target the right IDs."
  value       = [for v in data.proxmox_virtual_environment_vms.all.vms : "${v.vm_id} ${v.name} (${v.node_name}, ${v.status})"]
}
