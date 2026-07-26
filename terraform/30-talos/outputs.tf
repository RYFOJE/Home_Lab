output "kubeconfig" {
  description = "Kubeconfig for the Talos cluster. Consumed by layer 40-kube-networking via terraform_remote_state."
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
  description = "Node name -> eth1 storage IP (VLAN 12); 40-kube-networking excludes these from the whereabouts range."
  value       = local.storage_ips
}

output "longhorn_v2_data_engine" {
  description = "Whether the Longhorn v2 data engine's node prerequisites (hugepages, kernel modules) are in place. Consumed by 40-kube-networking so the chart setting cannot disagree with the node config that supports it."
  value       = var.longhorn_v2_data_engine
}

output "kubernetes_version" {
  description = "Pinned Kubernetes control-plane version, for reference by upgrade tooling and runbooks."
  value       = var.kubernetes_version
}
