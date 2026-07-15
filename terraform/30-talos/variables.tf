variable "cluster_name" {
  description = "Talos/Kubernetes cluster name"
  type        = string
  default     = "london"
}

variable "cluster_vip" {
  description = "Control-plane virtual IP (Talos native VIP, replaces kube-vip). Kube API served here on :6443."
  type        = string
  default     = "10.1.11.10"
}

variable "workloads_gateway" {
  description = "Default gateway on VLAN 11 (router sub-interface)"
  type        = string
  default     = "10.1.11.1"
}

variable "pod_cidr" {
  description = "Pod-to-pod CIDR (allocations.md: /22 supports max 4 nodes at /24-per-node)"
  type        = string
  default     = "10.1.200.0/22"
}

variable "service_cidr" {
  description = "ClusterIP service CIDR (allocations.md)"
  type        = string
  default     = "10.1.204.0/24"
}

variable "storage_mtu" {
  description = "MTU for eth1 on the VLAN 12 storage island. Must match the VM NIC set by 20-proxmox and the physical path (bridge/switch)."
  type        = number
  default     = 9000
}

variable "install_disk" {
  description = "Disk Talos installs to. Matches the virtio0 disk from 20-proxmox (/dev/vda)."
  type        = string
  default     = "/dev/vda"
}
