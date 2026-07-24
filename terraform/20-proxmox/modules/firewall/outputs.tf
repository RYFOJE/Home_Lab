output "ipset_names" {
  description = "Map key -> PVE IPSet name (reference in rules as \"+<name>\")."
  value       = { for k, v in proxmox_virtual_environment_firewall_ipset.this : k => v.name }
}

output "security_group_names" {
  description = "Map key -> PVE security group name."
  value       = { for k, v in proxmox_virtual_environment_cluster_firewall_security_group.this : k => v.name }
}
