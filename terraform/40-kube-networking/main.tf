# Edge secrets (public domain, ACME email) come from Azure Key Vault -- never
# committed (README rule). Same pattern as 10-network.
#
# The Cloudflare DNS token is deliberately NOT read here any more: cert-manager
# receives it through External Secrets Operator like every other in-cluster
# secret (cert-manager.tf), so it never enters this layer's state.
provider "azurerm" {
  features {}
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

# The owned public domain -- treated as PII, so it lives in Key Vault too.
data "azurerm_key_vault_secret" "public_domain" {
  name         = "public-domain"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "acme_email" {
  name         = "acme-email"
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

  # eth1 IPs on VLAN 12; excluded from the whereabouts range in multus.tf
  node_storage_ips = data.terraform_remote_state.talos.outputs.node_storage_ips

  # Owned by 30-talos, which sets the hugepages and kernel modules the engine
  # needs. Consumed by longhorn.tf so the switch and its prerequisites cannot
  # disagree.
  longhorn_v2_data_engine = data.terraform_remote_state.talos.outputs.longhorn_v2_data_engine
}

provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca_certificate
  client_certificate     = local.kube_client_cert
  client_key             = local.kube_client_key
}

provider "helm" {
  # Attribute, not a block: the helm provider was rewritten on the plugin
  # framework in v3 and `kubernetes` became a nested attribute.
  kubernetes = {
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
