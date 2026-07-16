variable "address_groups" {
  description = "Map of firewall address groups (unifi_firewall_group type 'address-group')."
  type = map(object({
    name    = string
    members = list(string)
  }))
  default = {}
}

variable "port_groups" {
  description = "Map of firewall port groups (unifi_firewall_group type 'port-group')."
  type = map(object({
    name    = string
    members = list(string)
  }))
  default = {}
}

variable "rules" {
  description = "Map of firewall rules. Key is the rule ID from firewall_rules.yaml (e.g. \"FW-001\")."
  type = map(object({
    name       = string
    action     = string # "accept" | "drop" | "reject"
    ruleset    = string # e.g. "LAN_IN", "LAN_LOCAL", "WAN_OUT"
    rule_index = number
    protocol   = optional(string)

    src_network_id        = optional(string) # existing unifi_network id, if matching by network
    src_address           = optional(string) # raw IP/CIDR, if matching by address
    src_address_group_key = optional(string) # key into address_groups
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
  description = "WAN port forwards (DNAT). Key by rule ID from firewall_rules.yaml (e.g. \"FW-017\")."
  type = map(object({
    name         = string
    protocol     = string # "tcp" | "udp" | "tcp_udp"
    wan_port     = string
    forward_ip   = string
    forward_port = string
    logging      = optional(bool)
  }))
  default = {}
}
