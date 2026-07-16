output "rules" {
  description = "Map of created unifi_firewall_rule resources, keyed by rule ID."
  value       = unifi_firewall_rule.this
}

output "port_forwards" {
  description = "Map of created unifi_port_forward resources, keyed by rule ID."
  value       = unifi_port_forward.this
}
