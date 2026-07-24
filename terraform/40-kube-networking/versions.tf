terraform {
  required_version = ">= 1.7.0"

  backend "azurerm" {
    resource_group_name  = "terraform"
    storage_account_name = "rjterraform"
    container_name       = "london"
    # Renamed from "40-Kube-Networking.tfstate" (pre-rename casing). On an
    # existing deployment run `terraform init -migrate-state` once -- a plain
    # init -reconfigure would start from empty state and re-create the layer.
    key              = "40-kube-networking.tfstate"
    use_azuread_auth = true
  }

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubectl = {
      source  = "alekc/kubectl" # maintained fork of gavinbunney/kubectl
      version = "~> 2.1"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
