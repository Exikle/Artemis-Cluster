variable "truenas_endpoint" {
  type        = string
  description = "TrueNAS versioned JSON-RPC WebSocket endpoint on atlas."
  default     = "wss://10.10.99.100:1443/api/current"
}

variable "truenas_api_key" {
  type        = string
  description = "TrueNAS API key. Supplied from 1Password via secrets.env."
  sensitive   = true
}

provider "truenas" {
  endpoint = var.truenas_endpoint
  api_key  = var.truenas_api_key

  # atlas serves the API with its own self-signed certificate.
  insecure = true

  # `username` alongside `api_key` selects SCRAM-SHA-512, which is 26.0+ only.
  # atlas runs 25.10, so it is deliberately omitted and the plain key login is used.
}
