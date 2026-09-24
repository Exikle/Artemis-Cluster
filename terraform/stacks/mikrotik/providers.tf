variable "routeros_hosturl" {
  type        = string
  description = "CRS309 API over TLS. Its only address is on the TRANSIT /30 behind the UCG."
  default     = "apis://172.16.99.2:8729"
}

variable "routeros_username" {
  type        = string
  description = "RouterOS user the provider logs in as."
  default     = "admin"
}

variable "routeros_password" {
  type        = string
  description = "RouterOS password. Supplied from 1Password via secrets.env."
  sensitive   = true
}

provider "routeros" {
  hosturl  = var.routeros_hosturl
  username = var.routeros_username
  password = var.routeros_password

  # api-ssl serves the switch's own self-signed `tofu-api` certificate.
  insecure = true
}
