provider "azurerm" {
  features {}
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

data "azurerm_key_vault_secret" "proxmox_api_token" {
  name         = "proxmox-api-token"
  key_vault_id = data.azurerm_key_vault.this.id
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = data.azurerm_key_vault_secret.proxmox_api_token.value
  insecure  = var.proxmox_insecure
}
