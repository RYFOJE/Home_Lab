resource "unifi_network" "this" {
  for_each = var.networks

  name    = each.value.name
  purpose = each.value.purpose
  vlan    = each.value.vlan
  subnet  = each.value.subnet

  # vlan-only networks have no L3 interface, so no DHCP config is sent.
  dhcp_server = each.value.dhcp_enabled ? {
    enabled = true
    start   = each.value.dhcp_start
    stop    = each.value.dhcp_stop
  } : null
}
