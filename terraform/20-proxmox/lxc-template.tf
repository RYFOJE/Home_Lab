# The Debian template every LXC in this layer boots from. Shared rather than
# owned by one container group: the datastores are host-local, so the download
# is per Proxmox host, and two resources pointing at the same url/datastore/node
# would manage one volume id twice.

locals {
  # One download per distinct Proxmox host running a Debian LXC, across every
  # container group in this layer.
  debian_template_pve_nodes = toset(concat(
    [for c in var.core_infra : c.pve_node],
    [for a in var.azdo_agents : a.pve_node],
  ))
}

resource "proxmox_download_file" "debian_template" {
  for_each = local.debian_template_pve_nodes

  node_name    = each.value
  datastore_id = var.image_datastore_id
  content_type = "vztmpl"
  url          = var.debian_template_url
}
