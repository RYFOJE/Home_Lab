# Non-secret configuration for the 30-talos layer. Safe to commit: this layer
# reads no Key Vault secrets (documentation/secrets.md) -- machine secrets and
# the kubeconfig are generated into Terraform state.
#
# Node IPs, storage IPs, and the factory installer image all come from the
# 20-proxmox remote state -- nothing node-specific to set here.
#
# Topology: 3 combined control-plane+worker nodes (allocations.md);
# allowSchedulingOnControlPlanes is set in the machine config patch.

cluster_name = "london"

# Control-plane VIP (Talos-native, replaces kube-vip). Must be free in VLAN 11.
cluster_vip       = "10.1.11.10"
workloads_gateway = "10.1.11.1"

# allocations.md "Kubernetes Overlay": /22 pod CIDR caps the cluster at 4 nodes.
pod_cidr     = "10.1.200.0/22"
service_cidr = "10.1.204.0/24"

# Jumbo frames on the VLAN 12 storage island -- must match 20-proxmox and the
# physical path.
storage_mtu = 9000

# virtio0 disk from 20-proxmox
install_disk = "/dev/vda"
