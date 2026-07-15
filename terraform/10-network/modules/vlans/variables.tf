variable "networks" {
  description = "Map of VLANs to create. Key is an internal identifier, not the VLAN ID."
  type = map(object({
    name         = string
    vlan         = number
    subnet       = string # CIDR, e.g. "10.1.12.0/24"
    dhcp_enabled = bool
    dhcp_start   = optional(string) # required if dhcp_enabled = true
    dhcp_stop    = optional(string) # required if dhcp_enabled = true
  }))
}
