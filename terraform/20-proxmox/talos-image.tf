# Talos Image Factory schematic: bakes the system extensions Longhorn needs
# (iscsi-tools for volume attach, util-linux-tools for fstrim) into the image.
# 30-talos reads schematic_id/installer_image from this layer's remote state so
# upgrades keep the extensions (machine.install.image).

data "talos_image_factory_extensions_versions" "this" {
  talos_version = var.talos_version
  filters = {
    names = [
      "iscsi-tools",
      "util-linux-tools",
    ]
  }
}

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = data.talos_image_factory_extensions_versions.this.extensions_info[*].name
      }
    }
  })
}

locals {
  # nocloud (not metal ISO): VLAN 11 has no DHCP, so nodes get their static IPs
  # from Proxmox cloud-init at first boot instead of maintenance mode.
  talos_image_url = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/${var.talos_version}/nocloud-amd64.qcow2"
  installer_image = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}:${var.talos_version}"

  # One image download per distinct Proxmox host (local datastores).
  image_pve_nodes = toset([for n in var.nodes : n.pve_node])
}

resource "proxmox_download_file" "talos_nocloud" {
  for_each = local.image_pve_nodes

  node_name    = each.value
  datastore_id = var.image_datastore_id
  content_type = "iso"
  url          = local.talos_image_url
  # .img suffix so Proxmox accepts it for disk import (it is a qcow2; qemu detects format)
  file_name = "talos-${var.talos_version}-${substr(talos_image_factory_schematic.this.id, 0, 8)}-nocloud-amd64.img"
}
