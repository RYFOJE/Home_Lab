output "networks" {
  description = "Map of created unifi_network resources, keyed same as var.networks."
  value       = unifi_network.this
}
