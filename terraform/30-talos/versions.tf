terraform {
  required_version = ">= 1.7.0"

  backend "azurerm" {
    resource_group_name  = "terraform"
    storage_account_name = "rjterraform"
    container_name       = "london"
    key                  = "30-talos.tfstate"
    use_azuread_auth     = true
  }

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }
  }
}
