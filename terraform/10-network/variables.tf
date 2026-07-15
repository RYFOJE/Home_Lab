variable "unifi_api_url" {
  description = "URL of the UniFi controller API (e.g. https://10.0.10.1/)"
  type        = string
}

variable "unifi_username" {
  description = "Local UniFi controller user for Terraform (not a Ubiquiti cloud account)"
  type        = string
}

variable "key_vault_name" {
  description = "Name of the Azure Key Vault holding this layer's secrets"
  type        = string
}

variable "key_vault_resource_group_name" {
  description = "Resource group containing key_vault_name"
  type        = string
}

variable "unifi_insecure" {
  description = "Skip TLS verification for the controller (true if using a self-signed cert)"
  type        = bool
  default     = true
}

variable "networks" {
  description = "VLANs to create. See modules/vlans for shape. Populate from documentation/networking/allocations.md."
  type = map(object({
    name         = string
    vlan         = number
    subnet       = string
    dhcp_enabled = bool
    dhcp_start   = optional(string)
    dhcp_stop    = optional(string)
  }))
  default = {}
}

variable "wlan_configs" {
  description = "Non-secret SSID settings, keyed by internal id. Safe to commit / set in a checked-in tfvars. Passphrases come from wlan_passphrases instead."
  type = map(object({
    name             = string
    vlan             = number
    user_group_id    = string
    security         = string
    wpa3_support     = optional(bool, false)
    wpa3_transition  = optional(bool, false)
    client_isolation = optional(bool, false)
  }))
  default = {}
}

variable "firewall_address_groups" {
  description = "Firewall address groups. See modules/firewall for shape."
  type = map(object({
    name    = string
    members = list(string)
  }))
  default = {}
}

variable "firewall_port_groups" {
  description = "Firewall port groups. See modules/firewall for shape."
  type = map(object({
    name    = string
    members = list(string)
  }))
  default = {}
}

variable "firewall_rules" {
  description = "Firewall rules. Key by rule ID from documentation/networking/firewall_rules.yaml (e.g. \"FW-001\")."
  type = map(object({
    name       = string
    action     = string
    ruleset    = string
    rule_index = number
    protocol   = optional(string)

    src_network_id        = optional(string)
    src_address           = optional(string)
    src_address_group_key = optional(string)
    src_port              = optional(string)

    dst_network_id        = optional(string)
    dst_address           = optional(string)
    dst_address_group_key = optional(string)
    dst_port              = optional(string)
  }))
  default = {}
}
