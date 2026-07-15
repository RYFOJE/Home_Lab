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
