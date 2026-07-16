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
    purpose      = optional(string, "corporate") # "vlan-only" = L2 only, no gateway sub-interface
    vlan         = number
    subnet       = optional(string) # omit for vlan-only networks
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
    network_key      = string # key into var.networks; resolved to the unifi_network id in main.tf
    user_group_id    = string
    security         = string
    wpa3_support     = optional(bool, false)
    wpa3_transition  = optional(bool, false)
    client_isolation = optional(bool, false)
    wlan_band        = optional(string) # e.g. "2g"; null = all bands
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

    state_established = optional(bool)
    state_related     = optional(bool)
  }))
  default = {}
}

variable "port_forwards" {
  description = "WAN port forwards (DNAT). See modules/firewall for shape. Key by rule ID from firewall_rules.yaml."
  type = map(object({
    name         = string
    protocol     = string
    wan_port     = string
    forward_ip   = string
    forward_port = string
    logging      = optional(bool)
  }))
  default = {}
}

variable "port_profiles" {
  description = "Switch port profiles. See modules/devices for shape. Populate from documentation/networking/physical_network.md."
  type = map(object({
    name                = string
    forward             = string
    native_network_key  = optional(string)
    tagged_network_keys = optional(list(string))
    poe_mode            = optional(string)
  }))
  default = {}
}

variable "devices" {
  description = "UniFi devices to manage. See modules/devices for shape; mac = null skips the device until adopted."
  type = map(object({
    name               = string
    mac                = optional(string)
    mgmt_network_key   = optional(string)
    jumboframe_enabled = optional(bool)
    static_ip = optional(object({
      ip      = string
      netmask = string
      gateway = string
      dns1    = optional(string)
      dns2    = optional(string)
    }))
    ports = optional(map(string))
  }))
  default = {}
}
