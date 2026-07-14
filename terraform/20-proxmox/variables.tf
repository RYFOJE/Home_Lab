variable "proxmox_endpoint" {
  description = "URL of the Proxmox VE API (e.g. https://10.0.10.11:8006/)"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox VE API token, in the form 'user@realm!token-name=uuid'"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification for the Proxmox API (true if using a self-signed cert)"
  type        = bool
  default     = true
}
