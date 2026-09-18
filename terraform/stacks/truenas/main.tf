# This stack is adopted, never authored: every resource here was imported from an
# object that already existed on atlas, and `tofu plan` must report no changes.
#
# Deliberately NOT managed here:
#
#   * The `atlas` pool. Pool topology is the one thing on this box that cannot be
#     rebuilt from a plan, so it is read as a data source and given no destroy path.
#   * The `media` SMB share (id 7). It carries `auxsmbconf = "force user = kubernetes
#     / force group = kubernetes"`, and the provider's `truenas_smb_share` has no
#     `auxsmbconf` attribute — so tofu cannot represent the one setting that makes the
#     share usable by the cluster. Left live-only rather than managed half-way.
#   * `/etc/netdata/exporting.conf` and its POSTINIT restore hook. File content on a
#     box, not an API object; Ansible's `roles/netdata_exporter` owns it.
#
# Dataset `type`/`compression` must be lowercase — see the TrueNAS traps in
# `.agents/references/terraform.md`, which is canonical for the reasoning.

data "truenas_pool" "atlas" {
  name = "atlas"
}

output "pool_free_bytes" {
  description = "Free space on atlas — proves the API key authenticates."
  value       = data.truenas_pool.atlas.free
}
