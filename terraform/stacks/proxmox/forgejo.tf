# Forgejo LXC, built fresh rather than adopted — see the header in main.tf for why the old
# community-scripts container (105) was never imported. Built as 106 and swapped into ID 105
# by hand (.agents/references/ansible.md § Rebuilding the Forgejo container); the config
# below describes the post-swap container.
#
# template_file_id and the root key cannot be read back from a running guest, and both are
# ForceNew, so after the swap-and-import they are ignored rather than planned as a replace.
resource "proxmox_virtual_environment_container" "forgejo" {
  description   = "Forgejo — git.dcunha.io. Configured by ansible/playbooks/forgejo.yml."
  node_name     = "pantheon"
  start_on_boot = true
  started       = true
  tags          = ["forgejo", "lxc"]
  unprivileged  = true
  vm_id         = 105

  cpu {
    cores = 2
  }

  disk {
    datastore_id = "vmpool"
    size         = 8
  }

  features {
    nesting = true
  }

  initialization {
    hostname = "forgejo"

    dns {
      domain  = "dcunha.io"
      servers = ["10.10.99.1"]
    }

    ip_config {
      ipv4 {
        address = "10.10.99.24/24"
        gateway = "10.10.99.1"
      }
    }

    user_account {
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEBUi7VNoe7FM+UZclUnPidc94GKejxzgadCfAbuFDtR",
      ]
    }
  }

  memory {
    dedicated = 4096
    swap      = 512
  }

  # Forgejo's whole state: repos, SQLite, packages, LFS. Its own volume so the OS and the
  # data can be snapshotted and rebuilt apart. backup = true is load-bearing — a volume
  # mount point is left out of vzdump unless it is set.
  mount_point {
    backup = true
    path   = "/var/lib/forgejo"
    size   = "40G"
    volume = "vmpool"
  }

  # The MAC is the original container's, kept so UniFi and the gateway's SSH proxy see the
  # same client after the swap.
  network_interface {
    bridge      = "vmbr0"
    firewall    = false
    mac_address = "BC:24:11:45:47:61"
    name        = "eth0"
    vlan_id     = 1099
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }

  lifecycle {
    ignore_changes = [
      initialization[0].user_account,
      operating_system[0].template_file_id,
    ]
  }
}
