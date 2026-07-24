output "node_ips" {
  description = "Node name -> eth0 IP on VLAN 11 (Talos API + kubelet). Consumed by 30-talos."
  value       = { for name, n in var.nodes : name => n.ip }
}

output "node_storage_ips" {
  description = "Node name -> eth1 IP on VLAN 12 (Longhorn storage network). Consumed by 30-talos."
  value       = { for name, n in var.nodes : name => n.storage_ip }
}

output "schematic_id" {
  description = "Talos Image Factory schematic ID (iscsi-tools + util-linux-tools baked in)"
  value       = talos_image_factory_schematic.this.id
}

output "installer_image" {
  description = "Factory installer image; 30-talos pins machine.install.image to this so upgrades keep extensions"
  value       = local.installer_image
}

output "dns_ntp_servers" {
  description = "core-infra LXC IPs, primary first (allocations.md resolver order). Consumed by 30-talos for machine nameservers/time servers."
  value       = local.core_infra_ips
}

output "talos_version" {
  description = "Talos version the images were built for"
  value       = var.talos_version
}
