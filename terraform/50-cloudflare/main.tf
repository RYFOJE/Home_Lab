# Edge secrets (Cloudflare token, account id, public domain) come from Azure
# Key Vault -- never committed (README rule). Same pattern as 40-kube-networking.
provider "azurerm" {
  features {}
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

# One authoritative copy of the token, read two ways: here for the tunnel and
# the public DNS records, and by External Secrets Operator for cert-manager's
# DNS-01 solver. Scopes: Zone -> DNS -> Edit, Zone -> Zone -> Read,
# Account -> Cloudflare Tunnel -> Edit (secrets.md).
#
# The cert-manager-- prefix is not about this layer. Key Vault keys ESO reads
# are named <namespace>--<name> and a Kyverno policy checks that prefix against
# the requesting namespace, so the vault name is fixed by the in-cluster path
# (kubernetes/apps/security/cluster-secrets). This layer follows it rather than
# keeping a second copy under the unprefixed name, which is a thing that drifts.
data "azurerm_key_vault_secret" "cloudflare_dns_api_token" {
  name         = "cert-manager--cloudflare-dns-api-token"
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
