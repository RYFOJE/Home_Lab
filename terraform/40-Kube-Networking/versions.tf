terraform {
  required_version = ">= 1.7.0"

  backend "azurerm" {
    resource_group_name  = "terraform"
    storage_account_name = "rjterraform"
    container_name       = "london"
    key                  = "40-apps.tfstate"
    use_azuread_auth     = true
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
  }
}
