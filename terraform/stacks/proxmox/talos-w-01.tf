# Adopted by import on 2026-08-22 from the live VM — not authored by hand.
# Any edit here changes real hardware on the next apply. Plan first, always.
resource "proxmox_virtual_environment_vm" "talos_w_01" {
  acpi                                 = true
  bios                                 = "ovmf"
  boot_order                           = ["virtio0"]
  delete_unreferenced_disks_on_destroy = true
  keyboard_layout                      = "en-us"
  machine                              = "q35"
  migrate                              = false
  name                                 = "talos-w-01"
  network_device = [{
    bridge       = "vmbr0"
    disconnected = false
    enabled      = true
    firewall     = false
    mac_address  = "BC:24:11:C2:B4:EC"
    model        = "virtio"
    mtu          = 0
    queues       = 0
    rate_limit   = 0
    trunks       = "1099;1152"
    vlan_id      = 0
  }]
  node_name           = "pantheon"
  on_boot             = true
  protection          = false
  purge_on_destroy    = true
  reboot              = false
  reboot_after_update = true
  scsi_hardware       = "virtio-scsi-single"
  started             = true
  stop_on_destroy     = false
  tablet_device       = true
  tags                = ["kubernetes", "talos", "worker"]
  template            = false
  timeout_clone       = 1800
  timeout_create      = 1800
  timeout_migrate     = 1800
  timeout_reboot      = 1800
  timeout_shutdown_vm = 1800
  timeout_start_vm    = 1800
  timeout_stop_vm     = 300
  vm_id               = 101
  agent {
    enabled = true
    timeout = "15m"
    trim    = false
    type    = "virtio"
  }
  cpu {
    cores      = 6
    flags      = []
    hotplugged = 0
    limit      = 0
    numa       = true
    sockets    = 1
    type       = "host"
  }
  disk {
    aio               = "io_uring"
    backup            = true
    cache             = "none"
    datastore_id      = "vmpool"
    discard           = "on"
    file_format       = "raw"
    interface         = "virtio0"
    iothread          = true
    path_in_datastore = "vm-101-disk-0"
    queues            = 0
    replicate         = true
    size              = 128
    ssd               = false
  }
  efi_disk {
    datastore_id      = "vmpool"
    file_format       = "raw"
    pre_enrolled_keys = false
    type              = "2m"
  }
  memory {
    dedicated      = 32768
    floating       = 0
    keep_hugepages = false
    shared         = 0
  }
  operating_system {
    type = "l26"
  }
  serial_device {
    device = "socket"
  }
}
