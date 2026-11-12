terraform {
  required_version = ">= 1.12.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.122.0"
    }
  }

  backend "local" {}
}
