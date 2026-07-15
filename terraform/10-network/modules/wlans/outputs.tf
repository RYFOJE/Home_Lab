output "wlans" {
  description = "Map of created unifi_wlan resources, keyed same as var.wlans."
  value       = unifi_wlan.this
}
