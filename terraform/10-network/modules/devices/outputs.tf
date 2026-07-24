output "port_profiles" {
  description = "Map of created unifi_port_profile resources, keyed same as var.port_profiles."
  value       = unifi_port_profile.this
}

output "devices" {
  description = "Map of managed unifi_device resources (adopted devices only), keyed same as var.devices."
  value       = unifi_device.this
}
