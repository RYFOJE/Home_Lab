variable "wlans" {
  description = "Map of SSIDs to create. Key is an internal identifier, not the SSID name."
  type = map(object({
    name             = string
    vlan             = number
    user_group_id    = string
    security         = string # e.g. "wpapsk"
    passphrase       = string
    wpa3_support     = optional(bool, false)
    wpa3_transition  = optional(bool, false)
    client_isolation = optional(bool, false)
  }))
}
