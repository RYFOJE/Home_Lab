# Adopt the default `local` dir storage so its content types are declared here
# (the Talos image download needs `iso` enabled on it).
#
# WARNING: once imported, Terraform owns this storage's full config. The
# `content` list below REPLACES whatever is live -- a type missing here gets
# stripped from the datastore. Run `terraform plan` after the import and
# reconcile against `pvesm status` / the current content list before applying.
import {
  to = proxmox_storage_directory.local
  id = "local"
}

resource "proxmox_storage_directory" "local" {
  id   = "local"
  path = "/var/lib/vz"

  content = var.local_storage_content
}
