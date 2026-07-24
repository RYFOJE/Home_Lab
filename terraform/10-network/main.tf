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
    for k, v in var.wlan_configs : k => {
      name = v.name
      # Resolving network_key -> unifi_network id also orders SSIDs after their VLANs.
      network_id       = module.vlans.networks[v.network_key].id
      user_group_id    = v.user_group_id
      security         = v.security
      passphrase       = data.azurerm_key_vault_secret.wlan_passphrase[k].value
      wpa3_support     = v.wpa3_support
      wpa3_transition  = v.wpa3_transition
      client_isolation = v.client_isolation
      wlan_band        = v.wlan_band
    }
  }
}

module "firewall" {
  source         = "./modules/firewall"
  address_groups = var.firewall_address_groups
  port_groups    = var.firewall_port_groups
  rules          = var.firewall_rules
  # Tunnel mode has zero WAN forwards -- the FW-017 entries only materialise
  # in dnat mode (firewall_rules.yaml FW-017).
  port_forwards = var.edge_mode == "dnat" ? var.port_forwards : {}
}

module "devices" {
  source = "./modules/devices"
  # Same key -> id resolution pattern as the wlans wiring; also orders device
  # config after the VLANs it references.
  network_ids   = { for k, v in module.vlans.networks : k => v.id }
  port_profiles = var.port_profiles
  devices       = var.devices
}
