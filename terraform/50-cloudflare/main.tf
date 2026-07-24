# Edge secrets (Cloudflare token, account id, public domain) come from Azure
# Key Vault -- never committed (README rule). Same pattern as 40-kube-networking.
provider "azurerm" {
  features {}
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

# Shared with cert-manager (40-kube-networking). Scopes: Zone -> DNS -> Edit,
# Zone -> Zone -> Read, Account -> Cloudflare Tunnel -> Edit (secrets.md).
data "azurerm_key_vault_secret" "cloudflare_dns_api_token" {
  name         = "cloudflare-dns-api-token"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "cloudflare_account_id" {
  name         = "cloudflare-account-id"
  key_vault_id = data.azurerm_key_vault.this.id
}

# The owned public domain -- treated as PII, so it lives in Key Vault too.
data "azurerm_key_vault_secret" "public_domain" {
  name         = "public-domain"
  key_vault_id = data.azurerm_key_vault.this.id
}

# edge_mode is owned by 10-network (its terraform.tfvars is the single source
# of truth); this layer consumes it rather than duplicating the value.
data "terraform_remote_state" "network" {
  backend = "azurerm"
  config = {
    resource_group_name  = "terraform"
    storage_account_name = "rjterraform"
    container_name       = "london"
    key                  = "10-network.tfstate"
    use_azuread_auth     = true
  }
}

# Names the external Traefik instance (the tunnel origin) -- read from
# 40-kube-networking instead of duplicating the "traefik-<name>" convention.
data "terraform_remote_state" "kube_networking" {
  backend = "azurerm"
  config = {
    resource_group_name  = "terraform"
    storage_account_name = "rjterraform"
    container_name       = "london"
    key                  = "40-kube-networking.tfstate"
    use_azuread_auth     = true
  }
}

locals {
  domain     = data.azurerm_key_vault_secret.public_domain.value
  account_id = data.azurerm_key_vault_secret.cloudflare_account_id.value
  edge_mode  = data.terraform_remote_state.network.outputs.edge_mode
}

provider "cloudflare" {
  api_token = data.azurerm_key_vault_secret.cloudflare_dns_api_token.value
}
