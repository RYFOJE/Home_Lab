resource "unifi_port_profile" "this" {
  for_each = var.port_profiles

  name                   = each.value.name
  forward                = each.value.forward
  native_networkconf_id  = each.value.native_network_key != null ? var.network_ids[each.value.native_network_key] : null
  tagged_networkconf_ids = each.value.tagged_network_keys != null ? [for k in each.value.tagged_network_keys : var.network_ids[k]] : null
  poe_mode               = each.value.poe_mode
}

resource "unifi_device" "this" {
  # Devices are adopted manually before Terraform can manage them; mac stays
  # null in tfvars until then, which drops the device from this for_each so the
  # rest of the layer still plans/applies.
  for_each = { for k, v in var.devices : k => v if v.mac != null }

  mac                = each.value.mac
  name               = each.value.name
  mgmt_network_id    = each.value.mgmt_network_key != null ? var.network_ids[each.value.mgmt_network_key] : null
  jumboframe_enabled = each.value.jumboframe_enabled

  config_network = each.value.static_ip != null ? {
    type    = "static"
    ip      = each.value.static_ip.ip
    netmask = each.value.static_ip.netmask
    gateway = each.value.static_ip.gateway
    dns1    = each.value.static_ip.dns1
    dns2    = each.value.static_ip.dns2
  } : null

  allow_adoption    = false # adoption is a manual step (physical_network.md)
  forget_on_destroy = false

  dynamic "port_override" {
    for_each = coalesce(each.value.ports, {})
    content {
      index           = tonumber(port_override.key)
      port_profile_id = unifi_port_profile.this[port_override.value].id
    }
  }
}
