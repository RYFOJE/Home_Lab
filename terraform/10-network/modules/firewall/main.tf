resource "unifi_firewall_group" "address" {
  for_each = var.address_groups

  name    = each.value.name
  type    = "address-group"
  members = each.value.members
}

resource "unifi_firewall_group" "port" {
  for_each = var.port_groups

  name    = each.value.name
  type    = "port-group"
  members = each.value.members
}

resource "unifi_firewall_rule" "this" {
  for_each = var.rules

  name       = each.value.name
  action     = each.value.action
  ruleset    = each.value.ruleset
  rule_index = each.value.rule_index
  protocol   = each.value.protocol

  src_network_id         = each.value.src_network_id
  src_address            = each.value.src_address
  src_firewall_group_ids = each.value.src_address_group_key != null ? [unifi_firewall_group.address[each.value.src_address_group_key].id] : null
  src_port               = each.value.src_port

  dst_network_id         = each.value.dst_network_id
  dst_address            = each.value.dst_address
  dst_firewall_group_ids = each.value.dst_address_group_key != null ? [unifi_firewall_group.address[each.value.dst_address_group_key].id] : null
  dst_port               = each.value.dst_port

  state_established = each.value.state_established
  state_related     = each.value.state_related
}

resource "unifi_port_forward" "this" {
  for_each = var.port_forwards

  name     = each.value.name
  protocol = each.value.protocol
  logging  = coalesce(each.value.logging, false)

  wan = {
    interface  = "wan"
    ip_address = "any"
    port       = each.value.wan_port
  }

  forward = {
    ip   = each.value.forward_ip
    port = each.value.forward_port
  }
}
