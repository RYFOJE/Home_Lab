# Node IPs and the extensions-baked installer image come from layer 20-proxmox.
data "terraform_remote_state" "proxmox" {
  backend = "azurerm"
  config = {
    resource_group_name  = "terraform"
    storage_account_name = "rjterraform"
    container_name       = "london"
    key                  = "20-proxmox.tfstate"
    use_azuread_auth     = true
  }
}

locals {
  # name -> eth0 IP (VLAN 11) and name -> eth1 IP (VLAN 12)
  nodes           = data.terraform_remote_state.proxmox.outputs.node_ips
  storage_ips     = data.terraform_remote_state.proxmox.outputs.node_storage_ips
  installer_image = data.terraform_remote_state.proxmox.outputs.installer_image
  talos_version   = data.terraform_remote_state.proxmox.outputs.talos_version

  # core-infra LXC IPs (primary first). Talos defaults (public resolvers,
  # time.cloudflare.com) are blocked by the firewall -- FW-001/002 only allow
  # DNS/NTP to these internal servers.
  dns_ntp_servers = data.terraform_remote_state.proxmox.outputs.dns_ntp_servers

  node_ips = sort(values(local.nodes))

  # All 3 nodes are combined control-plane + worker (allocations.md).
  # Per-node patch: static networking (VLAN 11 has no DHCP), Talos-native VIP,
  # Longhorn prereqs (bind mount, hugepages, v2-engine kernel modules).
  node_patches = {
    for name, ip in local.nodes : name => yamlencode({
      machine = {
        install = {
          disk = var.install_disk
          # Factory image with iscsi-tools + util-linux-tools; pinning it here
          # keeps the extensions across upgrades.
          image = local.installer_image
        }
        network = {
          hostname    = name
          nameservers = local.dns_ntp_servers
          interfaces = [
            {
              interface = "eth0"
              addresses = ["${ip}/24"]
              routes = [{
                network = "0.0.0.0/0"
                gateway = var.workloads_gateway
              }]
              vip = { ip = var.cluster_vip }
            },
            {
              # Longhorn storage network -- no routes by design (L2-only island).
              # MTU 9000 must match the Proxmox NIC (20-proxmox) and switch ports.
              interface = "eth1"
              addresses = ["${local.storage_ips[name]}/24"]
              mtu       = var.storage_mtu
            },
          ]
        }
        time = {
          servers = local.dns_ntp_servers
        }
        kubelet = {
          extraMounts = [{
            destination = "/var/lib/longhorn"
            type        = "bind"
            source      = "/var/lib/longhorn"
            options     = ["bind", "rshared", "rw"]
          }]
        }
        # Longhorn v2 data engine prereqs (SPDK / NVMe-over-TCP). Baked into every
        # node so enabling the engine later is a Longhorn-values-only change.
        # Reserves 2 GiB RAM per node (1024 x 2 MiB hugepages).
        sysctls = {
          "vm.nr_hugepages" = "1024"
        }
        kernel = {
          modules = [
            { name = "nvme_tcp" },
            { name = "vfio_pci" },
            { name = "uio_pci_generic" },
          ]
        }
      }
      cluster = {
        allowSchedulingOnControlPlanes = true
        # allocations.md: Project 1 virtual ranges (Talos defaults would clash with docs)
        network = {
          podSubnets     = [var.pod_cidr]
          serviceSubnets = [var.service_cidr]
        }
      }
    })
  }
}

resource "talos_machine_secrets" "this" {
  talos_version = local.talos_version
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.node_ips
}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.cluster_vip}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = local.talos_version
}

resource "talos_machine_configuration_apply" "node" {
  for_each                    = local.nodes
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = each.value
  config_patches              = [local.node_patches[each.key]]
}

# Bootstrap runs exactly once, against a single node.
resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.node]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.node_ips[0]
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.node_ips[0]
}
