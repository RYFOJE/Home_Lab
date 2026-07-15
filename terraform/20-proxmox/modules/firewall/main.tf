# PVE built-in firewall (layer 2 of firewall_rules.yaml: same-subnet VLAN 10
# traffic the router never sees). Datacenter rules land on every node's host
# input chain; security groups are attached to the firewall=1 LXC vNICs.
#
# PVE's firewall is stateful: established/related return traffic is accepted
# automatically, so no FW-000-style rule exists here.

resource "proxmox_virtual_environment_firewall_ipset" "this" {
  for_each = var.ipsets

  name    = each.value.name
  comment = each.value.comment

  dynamic "cidr" {
    for_each = each.value.members
    content {
      name = cidr.value
    }
  }
}

resource "proxmox_virtual_environment_cluster_firewall_security_group" "this" {
  for_each = var.security_groups

  name    = each.value.name
  comment = each.value.comment

  dynamic "rule" {
    for_each = each.value.rules
    content {
      comment = rule.value.comment
      type    = rule.value.type
      action  = rule.value.action
      source  = rule.value.source
      dest    = rule.value.dest
      proto   = rule.value.proto
      dport   = rule.value.dport
      sport   = rule.value.sport
      macro   = rule.value.macro
    }
  }

  # Rules reference ipsets by "+name" string -- no implicit graph edge, so
  # force creation order explicitly.
  depends_on = [proxmox_virtual_environment_firewall_ipset.this]
}

resource "proxmox_virtual_environment_firewall_rules" "cluster" {
  count = length(var.cluster_rules) > 0 ? 1 : 0

  dynamic "rule" {
    for_each = var.cluster_rules
    content {
      comment = rule.value.comment
      type    = rule.value.type
      action  = rule.value.action
      source  = rule.value.source
      dest    = rule.value.dest
      proto   = rule.value.proto
      dport   = rule.value.dport
      sport   = rule.value.sport
      macro   = rule.value.macro
    }
  }

  depends_on = [proxmox_virtual_environment_firewall_ipset.this]
}

resource "proxmox_virtual_environment_firewall_rules" "guest" {
  for_each = { for k, v in var.guests : k => v if length(v.security_groups) > 0 }

  node_name    = each.value.node_name
  vm_id        = each.value.vm_id
  container_id = each.value.container_id

  dynamic "rule" {
    for_each = each.value.security_groups
    content {
      security_group = proxmox_virtual_environment_cluster_firewall_security_group.this[rule.value].name
    }
  }
}

resource "proxmox_virtual_environment_firewall_options" "guest" {
  for_each = var.guests

  node_name    = each.value.node_name
  vm_id        = each.value.vm_id
  container_id = each.value.container_id

  enabled       = true
  input_policy  = each.value.input_policy
  output_policy = each.value.output_policy

  # Guest options only take effect once the vNIC's firewall flag is set AND
  # rules exist -- enable last so a guest is never live under default-deny
  # with an empty ruleset.
  depends_on = [proxmox_virtual_environment_firewall_rules.guest]
}

# Enable the datacenter firewall LAST: with input_policy DROP, flipping this
# on before the allow rules above exist would cut off the Proxmox API mid-apply.
resource "proxmox_virtual_environment_cluster_firewall" "this" {
  enabled       = var.cluster_options.enabled
  input_policy  = var.cluster_options.input_policy
  output_policy = var.cluster_options.output_policy

  depends_on = [
    proxmox_virtual_environment_firewall_rules.cluster,
    proxmox_virtual_environment_firewall_rules.guest,
    proxmox_virtual_environment_firewall_options.guest,
  ]
}
