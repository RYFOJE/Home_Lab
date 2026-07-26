# All values live in terraform.tfvars -- no defaults here, so a missing value
# fails the plan loudly instead of silently applying a stale default (same
# convention as the other layers). Node IPs, storage IPs, and the installer
# image come from the 20-proxmox remote state, not variables.

variable "cluster_name" {
  description = "Talos/Kubernetes cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the control plane. Pinned explicitly: unset, the talos provider substitutes whatever default its own build carries, so a provider patch bump would move the control-plane version with nothing in the diff naming it."
  type        = string
}

variable "longhorn_v2_data_engine" {
  description = "Enable the Longhorn v2 data engine (SPDK / NVMe-over-TCP). Owned here because the prerequisites are node-level: 1024 hugepages (2 GiB of RAM per node, unavailable for anything else once reserved) and three kernel modules. 40-kube-networking reads this through remote state for the Longhorn chart, so the switch and its prerequisites cannot disagree. Enabling it reboots nodes."
  type        = bool
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

variable "key_vault_name" {
  description = "Azure Key Vault the admin-access copies of talosconfig/kubeconfig are written to (documentation/infrastructure/disaster_recovery.md). This layer reads no secrets -- it only writes."
  type        = string
}

variable "key_vault_resource_group_name" {
  description = "Resource group holding key_vault_name"
  type        = string
}
