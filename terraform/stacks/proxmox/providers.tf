variable "pve_endpoint" {
  type        = string
  description = "Proxmox VE API endpoint for pantheon."
  default     = "https://10.10.99.104:8006/"
}

variable "pve_user" {
  type        = string
  description = "PVE user in user@realm form. Supplied from 1Password via secrets.env."
  sensitive   = true
}

variable "pve_token_name" {
  type        = string
  description = "PVE API token name. Supplied from 1Password via secrets.env."
  sensitive   = true
}

variable "pve_token_value" {
  type        = string
  description = "PVE API token secret. Supplied from 1Password via secrets.env."
  sensitive   = true
}

provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = "${var.pve_user}!${var.pve_token_name}=${var.pve_token_value}"

  # pantheon serves the PVE API with its own self-signed certificate.
  insecure = true
}
