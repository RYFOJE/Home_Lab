output "kubeconfig" {
  description = "Kubeconfig for the Talos cluster. Consumed by layer 40-Kube-Networking via terraform_remote_state."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Client config for talosctl (talosctl --talosconfig <this> ...)."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint (Talos-native control-plane VIP)."
  value       = "https://${var.cluster_vip}:6443"
}

output "node_ips" {
  description = "Node name -> eth0 IP passthrough for downstream layers."
  value       = local.nodes
}

output "node_storage_ips" {
  description = "Node name -> eth1 storage IP (VLAN 12); 40-Kube-Networking excludes these from the whereabouts range."
  value       = local.storage_ips
}
