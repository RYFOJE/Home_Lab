terraform {
  required_version = ">= 1.7.0"

  backend "azurerm" {
    resource_group_name  = "terraform"
    storage_account_name = "rjterraform"
    container_name       = "london"
    key                  = "50-cloudflare.tfstate"
    use_azuread_auth     = true
  }

  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
      # >= 5.7 required: fixes the tunnel-config perpetual-diff bug.
      version = "~> 5.22"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
