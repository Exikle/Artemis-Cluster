# mapall_user/group is `kubernetes` (uid 1000) on every share — the cluster is the
# only consumer, and kopiur's mover identity depends on it. Changing it breaks
# on-disk ownership for every app that mounts these.

resource "truenas_nfs_share" "media" {
  path         = "/mnt/atlas/media"
  comment      = "Media library and downloads"
  enabled      = true
  mapall_user  = "kubernetes"
  mapall_group = "kubernetes"
}

resource "truenas_nfs_share" "frigate" {
  path         = "/mnt/atlas/frigate"
  enabled      = true
  networks     = ["10.10.0.0/16"]
  mapall_user  = "kubernetes"
  mapall_group = "kubernetes"
}

resource "truenas_nfs_share" "kopiur" {
  path         = "/mnt/atlas/Kopiur"
  comment      = "kopiur backup repository"
  enabled      = true
  networks     = ["10.10.0.0/16"]
  mapall_user  = "kubernetes"
  mapall_group = "kubernetes"
}
