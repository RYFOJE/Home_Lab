mock_provider "azurerm" {
  override_during = plan

  mock_data "azurerm_key_vault" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.KeyVault/vaults/test"
    }
  }

  mock_data "azurerm_key_vault_secret" {
    defaults = {
      value = "example.test"
    }
  }
}

mock_provider "kubernetes" {
  override_during = plan
}

mock_provider "helm" {
  override_during = plan
}

mock_provider "kubectl" {
  override_during = plan

  mock_data "kubectl_file_documents" {
    defaults = {
      manifests = {}
    }
  }
}

mock_provider "talos" {
  override_during = plan
}

override_data {
  target = data.terraform_remote_state.talos
  values = {
    outputs = {
      kubeconfig  = <<-YAML
        apiVersion: v1
        clusters:
          - cluster:
              certificate-authority-data: Y2E=
              server: https://10.1.11.10:6443
            name: test
        contexts: []
        current-context: test
        kind: Config
        users:
          - name: test
            user:
              client-certificate-data: Y3J0
              client-key-data: a2V5
      YAML
      talosconfig = <<-YAML
        context: test
        contexts:
          test:
            ca: Y2E=
            crt: Y3J0
            key: a2V5
            endpoints:
              - 10.1.11.11
      YAML
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
      longhorn_v2_data_engine = false
    }
  }
}

variables {
  key_vault_name                = "test"
  key_vault_resource_group_name = "test"
  storage_network_cidr          = "10.1.12.0/24"
  storage_network_mtu           = 9000
  cilium_chart_version          = "1.19.6"
  cert_manager_chart_version    = "v1.21.0"
  longhorn_chart_version        = "1.12.0"
  traefik_chart_version         = "41.0.2"
  traefik_crds_chart_version    = "1.18.0"
}

run "post_cilium_gate_enables_kubernetes_checks" {
  command = plan

  assert {
    condition     = !data.talos_cluster_health.post_cilium.skip_kubernetes_checks
    error_message = "The layer-40 health gate must run the Kubernetes checks after Cilium."
  }

  # Values pass through unmodified: the provider decodes them itself, so a
  # base64decode here breaks the read (main.tf).
  assert {
    condition = local.talos_client_configuration == {
      ca_certificate     = "Y2E="
      client_certificate = "Y3J0"
      client_key         = "a2V5"
    }
    error_message = "The post-Cilium gate must authenticate from the sensitive talosconfig remote-state output, base64 as stored."
  }
}
