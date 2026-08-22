# Auth check only. No resources are declared yet — this stack is being adopted
# by import, so nothing here may ever create anything on its first apply.
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
