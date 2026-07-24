# core-infra DNS/NTP LXCs (allocations.md: 10.0.10.4 primary, 10.0.10.5 secondary).
# Split across pve1/pve2 so losing one host doesn't take down both.
#
# Terraform creates the containers only. Technitium DNS + chrony install and
# config (zone transfer, blocklists) are manual/Ansible -- Proxmox LXCs have no
# cloud-init. Do this BEFORE applying 30-talos: the k8s nodes resolve and sync
# time against these IPs from first boot.

locals {
  # One template download per distinct Proxmox host running a core-infra LXC.
  core_infra_pve_nodes = toset([for c in var.core_infra : c.pve_node])
  core_infra_ips       = [for name in sort(keys(var.core_infra)) : var.core_infra[name].ip]
}

resource "proxmox_download_file" "debian_template" {
  for_each = local.core_infra_pve_nodes

  node_name    = each.value
  datastore_id = var.image_datastore_id
  content_type = "vztmpl"
  url          = var.debian_template_url
}

resource "proxmox_virtual_environment_container" "core_infra" {
  for_each = var.core_infra

  node_name     = each.value.pve_node
  vm_id         = each.value.ct_id
  description   = "DNS (Technitium) + NTP (chrony) -- see documentation/networking/allocations.md"
  unprivileged  = true
  started       = true
  start_on_boot = true

  cpu {
    cores = var.core_infra_cores
  }

  memory {
    dedicated = var.core_infra_memory_mb
  }

  disk {
    datastore_id = var.vm_datastore_id
    size         = var.core_infra_disk_gb
  }

  operating_system {
    template_file_id = proxmox_download_file.debian_template[each.value.pve_node].id
    type             = "debian"
  }

  network_interface {
    name    = "eth0"
    bridge  = var.network_bridge
    vlan_id = var.mgmt_vlan_id
    # firewall=1 per firewall_rules.yaml -- datacenter default-deny filters
    # this vNIC; the LXC-FW-* security group (firewall.tf) is what keeps
    # DNS/NTP reachable.
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

    # Final design: the LXCs resolve against themselves/each other. During the
    # initial Technitium install nothing answers on 53 yet -- point resolv.conf
    # at an upstream temporarily, then revert.
    dns {
      servers = local.core_infra_ips
    }

    user_account {
      keys = [var.core_infra_ssh_public_key]
    }
  }
}
