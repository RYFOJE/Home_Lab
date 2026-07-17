# Secrets (admin password, public domain) come from Azure Key Vault -- never
# committed (README rule). Same pattern as 40-kube-networking / 50-cloudflare.
provider "azurerm" {
  features {}
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

data "azurerm_key_vault_secret" "argocd_admin_password" {
  name         = "argocd-admin-password"
  key_vault_id = data.azurerm_key_vault.this.id
}

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
