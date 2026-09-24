# mapall_user/group is `kubernetes` (uid 1000) on every share — the cluster is the
# only consumer, and kopiur's mover identity depends on it. Changing it breaks
# on-disk ownership for every app that mounts these.
#
# Exports are limited to LAB. Every client is a Talos node mounting from its own LAB
# address (verified 2026-09-23 from atlas's established :2049 connections), and
# 10.10.0.0/16 also covered the Guest and IoT VLANs.

locals {
  nfs_networks = ["10.10.99.0/24"]
}

resource "truenas_nfs_share" "media" {
  path         = "/mnt/atlas/media"
  comment      = "Media library and downloads"
  enabled      = true
  networks     = local.nfs_networks
  mapall_user  = "kubernetes"
  mapall_group = "kubernetes"
}

resource "truenas_nfs_share" "frigate" {
  path         = "/mnt/atlas/frigate"
  enabled      = true
  networks     = local.nfs_networks
  mapall_user  = "kubernetes"
  mapall_group = "kubernetes"
}

resource "truenas_nfs_share" "kopiur" {
  path         = "/mnt/atlas/Kopiur"
  comment      = "kopiur backup repository"
  enabled      = true
  networks     = local.nfs_networks
  mapall_user  = "kubernetes"
  mapall_group = "kubernetes"
}
