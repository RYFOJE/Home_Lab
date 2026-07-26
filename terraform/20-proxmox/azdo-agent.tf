# Azure DevOps agent LXCs (allocations.md: 10.0.10.7, 10.0.10.8).
# Split across pve1/pve3 so a host reboot costs one agent, not every pipeline.
#
# Terraform creates the containers only -- Proxmox LXCs have no cloud-init. The
# agent, kubectl and helm are ansible/azdo-agent.yml
# (documentation/infrastructure/azdo_agents.md), which runs LAST in a rebuild:
# the ServiceAccount the agent authenticates to the cluster as is a GitOps
# object and does not exist until ArgoCD has converged.
#
# Separate from var.core_infra rather than more entries in it: that map feeds
# local.core_infra_ips, which is the resolver list every container gets and the
# dns_ntp_servers output 30-talos writes into machine.nameservers.

resource "proxmox_virtual_environment_container" "azdo_agent" {
  for_each = var.azdo_agents

  node_name     = each.value.pve_node
  vm_id         = each.value.ct_id
  description   = "Azure DevOps deployment agent -- see documentation/infrastructure/azdo_agents.md"
  unprivileged  = true
  started       = true
  start_on_boot = true

  cpu {
    cores = var.azdo_agent_cores
  }

  memory {
    dedicated = var.azdo_agent_memory_mb
  }

  disk {
    datastore_id = var.vm_datastore_id
    size         = var.azdo_agent_disk_gb
  }

  # No features block: builds run on Microsoft-hosted agents, so nothing here
  # needs a container runtime and the container stays unprivileged with no
  # nesting or keyctl.
  operating_system {
    template_file_id = proxmox_download_file.debian_template[each.value.pve_node].id
    type             = "debian"
  }

  network_interface {
    name    = "eth0"
    bridge  = var.network_bridge
    vlan_id = var.mgmt_vlan_id
    # firewall=1 per firewall_rules.yaml -- datacenter default-deny filters
    # this vNIC; the LXC-FW-007/008 security group (firewall.tf) is what keeps
    # SSH reachable for the Ansible play.
    firewall = true
  }

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.mgmt_gateway
      }
    }

    # The core-infra pair, serving long before these containers are configured.
    # FW-013 scopes outbound 53 to .4/.5, so this host has no public resolver to
    # fall back on -- see bootstrap_swap_resolver in ansible/roles/bootstrap.
    dns {
      servers = local.core_infra_ips
    }

    user_account {
      keys = [var.lxc_ssh_public_key]
    }
  }
}
