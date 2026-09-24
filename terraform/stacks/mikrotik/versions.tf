terraform {
  required_version = ">= 1.12.0"

  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.99.1"
    }
  }

  backend "local" {}
}
