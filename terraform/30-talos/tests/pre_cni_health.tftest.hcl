mock_provider "talos" {
  override_during = plan
}

mock_provider "azurerm" {
  override_during = plan

  mock_data "azurerm_key_vault" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.KeyVault/vaults/test"
    }
  }
}

override_data {
  target = data.terraform_remote_state.proxmox
  values = {
    outputs = {
      node_ips = {
        k8s-node-1 = "10.1.11.11"
        k8s-node-2 = "10.1.11.12"
        k8s-node-3 = "10.1.11.13"
      }
      node_storage_ips = {
        k8s-node-1 = "10.1.12.11"
        k8s-node-2 = "10.1.12.12"
        k8s-node-3 = "10.1.12.13"
      }
      installer_image = "factory.talos.dev/installer/mock:v1.13.7"
      talos_version   = "v1.13.7"
      dns_ntp_servers = ["10.0.10.4", "10.0.10.5"]
    }
  }
}

variables {
  cluster_name                  = "test"
  kubernetes_version            = "v1.36.2"
  longhorn_v2_data_engine       = false
  cluster_vip                   = "10.1.11.10"
  workloads_gateway             = "10.1.11.1"
  pod_cidr                      = "10.1.200.0/22"
  service_cidr                  = "10.1.204.0/24"
  storage_mtu                   = 9000
  install_disk                  = "/dev/vda"
  key_vault_name                = "test"
  key_vault_resource_group_name = "test"
}

run "pre_cni_health_skips_kubernetes" {
  command = plan

  assert {
    condition     = data.talos_cluster_health.pre_cni.skip_kubernetes_checks
    error_message = "The layer-30 health gate must skip Kubernetes checks before Cilium exists."
  }
}

run "cni_none_requires_skipping_kubernetes_checks" {
  command = plan

  assert {
    condition = alltrue([
      for node_patch in values(local.node_patches) :
      try(yamldecode(node_patch).cluster.network.cni.name, null) != "none" ||
      data.talos_cluster_health.pre_cni.skip_kubernetes_checks
    ])
    error_message = "Layer 30 cannot enable Kubernetes health checks while its Talos configuration leaves CNI set to none."
  }
}
