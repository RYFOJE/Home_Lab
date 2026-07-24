variable "networks" {
  description = "Map of VLANs to create. Key is an internal identifier, not the VLAN ID."
  type = map(object({
    name         = string
    purpose      = optional(string, "corporate") # "vlan-only" = L2 only, no gateway sub-interface
    vlan         = number
    subnet       = optional(string) # CIDR, e.g. "10.0.10.0/24"; omit for vlan-only networks
    dhcp_enabled = bool
    dhcp_start   = optional(string) # required if dhcp_enabled = true
    dhcp_stop    = optional(string) # required if dhcp_enabled = true
  }))
}
