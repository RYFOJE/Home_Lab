# All values live in terraform.tfvars -- no defaults here, so a missing value
# fails the plan loudly instead of silently applying a stale default (same
# convention as the other layers). Node IPs, storage IPs, and the installer
# image come from the 20-proxmox remote state, not variables.

variable "cluster_name" {
  description = "Talos/Kubernetes cluster name"
  type        = string
}

variable "cluster_vip" {
  description = "Control-plane virtual IP (Talos native VIP, replaces kube-vip). Kube API served here on :6443. Must be free in VLAN 11."
  type        = string
}

variable "workloads_gateway" {
  description = "Default gateway on VLAN 11 (router sub-interface)"
  type        = string
}

variable "pod_cidr" {
  description = "Pod-to-pod CIDR (allocations.md: /22 supports max 4 nodes at /24-per-node)"
  type        = string
}

variable "service_cidr" {
  description = "ClusterIP service CIDR (allocations.md)"
  type        = string
}

variable "storage_mtu" {
  description = "MTU for eth1 on the VLAN 12 storage island. Must match the VM NIC set by 20-proxmox and the physical path (bridge/switch)."
  type        = number
}

variable "install_disk" {
  description = "Disk Talos installs to. Matches the virtio0 disk from 20-proxmox (/dev/vda)."
  type        = string
}
