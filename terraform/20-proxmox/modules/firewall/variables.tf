variable "cluster_options" {
  description = "Datacenter-level firewall options. input_policy DROP is rule PVE-FW-900 (default-deny-inbound)."
  type = object({
    enabled       = bool
    input_policy  = string # "ACCEPT" | "DROP" | "REJECT"
    output_policy = string
  })
}

variable "ipsets" {
  description = "Cluster-level IPSets (address groups). Rules reference them as \"+<name>\"."
  type = map(object({
    name    = string
    comment = optional(string)
    members = list(string) # IPs or CIDRs
  }))
  default = {}
}

variable "security_groups" {
  description = "Cluster-level security groups: named, ordered rule lists attachable to guest vNICs. Key is referenced from var.guests.security_groups."
  type = map(object({
    name    = string
    comment = optional(string)
    rules = list(object({
      comment = optional(string) # carries the rule ID from firewall_rules.yaml
      type    = string           # "in" | "out"
      action  = string           # "ACCEPT" | "DROP" | "REJECT"
      source  = optional(string) # CIDR, IP, or "+<ipset-name>"
      dest    = optional(string)
      proto   = optional(string)
      dport   = optional(string) # PVE syntax: "80,443" / "5405:5412"
      sport   = optional(string)
      macro   = optional(string) # PVE macro (e.g. "DNS", "NTP", "Ping"); replaces proto/ports
    }))
  }))
  default = {}
}

variable "cluster_rules" {
  description = "Datacenter-level (host input chain) rules. ORDERED list -- position is evaluation order, first match wins, same as firewall_rules.yaml."
  type = list(object({
    comment = optional(string)
    type    = string
    action  = string
    source  = optional(string)
    dest    = optional(string)
    proto   = optional(string)
    dport   = optional(string)
    sport   = optional(string)
    macro   = optional(string)
  }))
  default = []
}

variable "guests" {
  description = "Per-guest (VM/CT) firewall: options plus security groups applied to the firewall=1 vNICs. Set exactly one of vm_id / container_id."
  type = map(object({
    node_name       = string
    vm_id           = optional(number)
    container_id    = optional(number)
    input_policy    = optional(string, "DROP") # PVE-FW-900 applies to LXC vNICs too
    output_policy   = optional(string, "ACCEPT")
    security_groups = optional(list(string), []) # keys into var.security_groups, in order
  }))
  default = {}
}
