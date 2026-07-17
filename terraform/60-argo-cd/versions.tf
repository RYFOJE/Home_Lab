terraform {
  required_version = ">= 1.7.0"

  backend "azurerm" {
    resource_group_name  = "terraform"
    storage_account_name = "rjterraform"
    container_name       = "london"
    key                  = "60-argo-cd.tfstate"
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
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
