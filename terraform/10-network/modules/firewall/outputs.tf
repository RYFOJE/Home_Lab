output "rules" {
  description = "Map of created unifi_firewall_rule resources, keyed by rule ID."
  value       = unifi_firewall_rule.this
}
