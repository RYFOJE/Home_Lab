variable "network_ids" {
  description = "Map of network key -> unifi_network id, used to resolve native/tagged network keys."
  type        = map(string)
  default     = {}
}

variable "port_profiles" {
  description = "Switch port profiles. Keys are referenced from devices[*].ports values."
  type = map(object({
    name                = string
    forward             = string           # "all" | "native" | "customize" | "disabled"
    native_network_key  = optional(string) # key into network_ids
    tagged_network_keys = optional(list(string))
    poe_mode            = optional(string) # "auto" | "off" | null (port default)
  }))
  default = {}
}

variable "devices" {
  description = <<-EOT
    UniFi devices (gateway/switch/AP) to manage. Devices with mac = null are
    skipped entirely -- fill in the MAC after manual adoption (see
    documentation/networking/physical_network.md bootstrap steps), then re-apply.
    `ports` maps switch port index (as string) -> key into port_profiles.
  EOT
  type = map(object({
    name               = string
    mac                = optional(string)
    mgmt_network_key   = optional(string) # key into network_ids
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
