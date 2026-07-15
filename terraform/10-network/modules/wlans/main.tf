resource "unifi_wlan" "this" {
  for_each = var.wlans

  name          = each.value.name
  network_id    = each.value.network_id
  user_group_id = each.value.user_group_id
  security      = each.value.security
  passphrase    = each.value.passphrase

  wpa3_support    = each.value.wpa3_support
  wpa3_transition = each.value.wpa3_transition
  l2_isolation    = each.value.client_isolation
  wlan_band       = each.value.wlan_band
}
