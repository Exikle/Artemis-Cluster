terraform {
  required_version = ">= 1.12.0"

  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "0.65.0"
    }
  }

  backend "local" {}
}
