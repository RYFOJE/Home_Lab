variable "proxmox_endpoint" {
  description = "URL of the Proxmox VE API (e.g. https://10.0.10.11:8006/)"
  type        = string
}

variable "key_vault_name" {
  description = "Name of the Azure Key Vault holding this layer's secrets"
  type        = string
}

variable "key_vault_resource_group_name" {
  description = "Resource group containing key_vault_name"
  type        = string
}

variable "proxmox_insecure" {
  description = "Skip TLS verification for the Proxmox API (true if using a self-signed cert)"
  type        = bool
  default     = true
}
