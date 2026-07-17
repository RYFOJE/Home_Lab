variable "storage_network_cidr" {
  description = "VLAN 12 Longhorn storage network (L2-only, no gateway)"
  type        = string
  default     = "10.1.12.0/24"
}

variable "storage_network_mtu" {
  description = "MTU for the macvlan storage-network attachment. Must match eth1 (30-talos) and the physical path."
  type        = number
  default     = 9000
}

variable "longhorn_v2_data_engine" {
  description = "Enable the Longhorn v2 data engine (SPDK / NVMe-over-TCP). Node prereqs (hugepages, nvme_tcp/vfio_pci/uio_pci_generic modules) are already baked in by 30-talos, so this is a values-only flip."
  type        = bool
  default     = false
}
