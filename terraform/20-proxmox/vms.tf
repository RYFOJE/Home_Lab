# Combined control-plane/worker nodes (allocations.md). Machine config, VIP,
# and Longhorn prereqs are applied by layer 30-talos over these static IPs.

resource "proxmox_virtual_environment_vm" "k8s_node" {
  for_each = var.nodes

  name      = each.key
  node_name = each.value.pve_node
  vm_id     = each.value.vm_id
  on_boot   = true

  machine = "q35"

  operating_system {
    type = "l26"
  }

  cpu {
    cores = var.vm_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  # Talos ships no qemu-guest-agent; enabling it would hang applies waiting for an IP.
  agent {
    enabled = false
  }

  disk {
    datastore_id = var.vm_datastore_id
    file_id      = proxmox_download_file.talos_nocloud[each.value.pve_node].id
    interface    = "virtio0"
    size         = var.vm_disk_gb
    iothread     = true
    discard      = "on"
  }

  # net0 -> eth0: Workloads VLAN 11.
  # firewall=0 on BOTH NICs per firewall_rules.yaml -- keeps cluster traffic
  # (6443, CNI, Longhorn, Cilium L2-announcement ARP) out of the PVE firewall
  # entirely; in-cluster policy is Kubernetes' job.
  network_device {
    bridge   = var.network_bridge
    vlan_id  = var.workloads_vlan_id
    firewall = false
  }

  # net1 -> eth1: Storage VLAN 12 (Longhorn replica traffic).
  # MTU 9000 per allocations.md -- the bridge and switch ports must also carry
  # jumbo frames (manual host/switch config), or large frames silently drop.
  network_device {
    bridge   = var.network_bridge
    vlan_id  = var.storage_vlan_id
    mtu      = var.storage_mtu
    firewall = false
  }

  # nocloud datasource: Talos reads these static IPs at first boot (VLAN 11 has no DHCP).
  initialization {
    datastore_id = var.vm_datastore_id

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.workloads_gateway
      }
    }

    # eth1: no gateway by design -- VLAN 12 is an L2-only island.
    ip_config {
      ipv4 {
        address = "${each.value.storage_ip}/24"
      }
    }
  }
}
