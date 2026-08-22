# READ ONLY. Nothing is managed here yet.
#
# This stack is the highest-risk one in the repo: a bad firewall apply severs the
# path it is being applied over and locks the operator out of their own network.
# Adoption is one object at a time, by import, and firewall zones come last.
data "unifi_network" "lab" {
  name = "LAB"
}

output "lab_network" {
  description = "Proves the API key authenticates and the site name resolves."
  value       = data.unifi_network.lab
}
