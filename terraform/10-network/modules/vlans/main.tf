resource "unifi_network" "this" {
  for_each = var.networks

  name    = each.value.name
  purpose = "corporate"
  vlan    = each.value.vlan
  subnet  = each.value.subnet

  dhcp_server = {
    enabled = each.value.dhcp_enabled
    start   = each.value.dhcp_enabled ? each.value.dhcp_start : null
    stop    = each.value.dhcp_enabled ? each.value.dhcp_stop : null
  }
}
