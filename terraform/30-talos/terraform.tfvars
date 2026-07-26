# Non-secret configuration for the 30-talos layer. Safe to commit: this layer
# reads no Key Vault secrets (documentation/secrets.md) -- machine secrets and
# the kubeconfig are generated into Terraform state. It does WRITE two: the
# break-glass talosconfig/kubeconfig copies (kv.tf), so that losing this
# layer's state does not also cost you access to a running cluster.

key_vault_name                = "rj-london"
key_vault_resource_group_name = "terraform"
#
# Node IPs, storage IPs, and the factory installer image all come from the
# 20-proxmox remote state -- nothing node-specific to set here.
#
# Topology: 3 combined control-plane+worker nodes (allocations.md);
# allowSchedulingOnControlPlanes is set in the machine config patch.

cluster_name = "london"

# Pinned deliberately, like every chart version in this repo. This is the
# default Kubernetes version for the pinned Talos release
# (DefaultKubernetesVersion in siderolabs/talos v1.13.7), so pinning it changes
# nothing about an already-built cluster -- it only stops a future provider
# build from moving the version silently. Talos v1.13 supports the six minors
# back from that default.
#
# Bumping it is an in-place control-plane upgrade with its own procedure --
# see ../../documentation/infrastructure/upgrades.md. Bump it in the same
# change as talos_version only when the new Talos release requires it.
kubernetes_version = "v1.36.2"

# Longhorn v2 data engine. Off: the node prerequisites cost 2 GiB of RAM per
# node in reserved hugepages, and nothing in this cluster uses the engine.
# 40-kube-networking reads this value from this layer's state.
longhorn_v2_data_engine = false

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
