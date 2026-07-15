provider "azurerm" {
  features {}
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

data "azurerm_key_vault_secret" "unifi_password" {
  name         = "unifi-password"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "wlan_passphrase" {
  for_each     = var.wlan_configs
  name         = "wlan-passphrase-${replace(each.key, "_", "-")}"
  key_vault_id = data.azurerm_key_vault.this.id
}

provider "unifi" {
  api_url        = var.unifi_api_url
  username       = var.unifi_username
  password       = data.azurerm_key_vault_secret.unifi_password.value
  allow_insecure = var.unifi_insecure
}

module "vlans" {
  source   = "./modules/vlans"
  networks = var.networks
}

module "wlans" {
  source = "./modules/wlans"
  wlans = {
    for k, v in var.wlan_configs : k => merge(v, {
      passphrase = data.azurerm_key_vault_secret.wlan_passphrase[k].value
    })
  }
}

module "firewall" {
  source         = "./modules/firewall"
  address_groups = var.firewall_address_groups
  port_groups    = var.firewall_port_groups
  rules          = var.firewall_rules
}
