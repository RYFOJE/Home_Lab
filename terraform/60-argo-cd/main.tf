# Secrets (admin password, public domain) come from Azure Key Vault -- never
# committed (README rule). Same pattern as 40-kube-networking / 50-cloudflare.
provider "azurerm" {
  features {}
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

# Pre-computed bcrypt hash (not the plaintext): Terraform's bcrypt() salts on
# every evaluation, so hashing here would diff the helm release on every plan.
# Generate with: argocd account bcrypt --password <pw>
data "azurerm_key_vault_secret" "argocd_admin_password_bcrypt" {
  name         = "argocd-admin-password-bcrypt"
  key_vault_id = data.azurerm_key_vault.this.id
}

# Service Principal that External Secrets Operator authenticates to Key Vault
# with (the azure-kv ClusterSecretStore). This is the one credential that
# cannot come from git and cannot come from ESO itself -- the bootstrap floor.
# Both are unprefixed: they are consumed by Terraform, not through ESO, so the
# namespace-prefix convention does not apply.
data "azurerm_key_vault_secret" "azure_kv_sp_client_id" {
  name         = "azure-kv-sp-client-id"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "azure_kv_sp_client_secret" {
  name         = "azure-kv-sp-client-secret"
  key_vault_id = data.azurerm_key_vault.this.id
}

# Tenant Terraform is logged into -- injected into the azure-kv store via the
# root Application so it stays out of git.
data "azurerm_client_config" "current" {}

# The owned public domain -- treated as PII, so it lives in Key Vault too.
data "azurerm_key_vault_secret" "public_domain" {
  name         = "public-domain"
  key_vault_id = data.azurerm_key_vault.this.id
}

# Kubeconfig comes from the 30-talos remote state -- no local file needed.
data "terraform_remote_state" "talos" {
  backend = "azurerm"
  config = {
    resource_group_name  = "terraform"
    storage_account_name = "rjterraform"
    container_name       = "london"
    key                  = "30-talos.tfstate"
    use_azuread_auth     = true
  }
}

# edge_mode is owned by 10-network (same pattern as 50-cloudflare): the root
# Application forwards it so the cloudflared app only renders in tunnel mode.
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

locals {
  kubeconfig = yamldecode(data.terraform_remote_state.talos.outputs.kubeconfig)

  kube_host           = local.kubeconfig.clusters[0].cluster.server
  kube_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
  kube_client_cert    = base64decode(local.kubeconfig.users[0].user["client-certificate-data"])
  kube_client_key     = base64decode(local.kubeconfig.users[0].user["client-key-data"])

  domain = data.azurerm_key_vault_secret.public_domain.value
}

provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca_certificate
  client_certificate     = local.kube_client_cert
  client_key             = local.kube_client_key
}

provider "helm" {
  kubernetes {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca_certificate
    client_certificate     = local.kube_client_cert
    client_key             = local.kube_client_key
  }
}

provider "kubectl" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca_certificate
  client_certificate     = local.kube_client_cert
  client_key             = local.kube_client_key
  load_config_file       = false
}
