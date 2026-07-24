# All values live in terraform.tfvars -- no defaults here, so a missing value
# fails the plan loudly instead of silently applying a stale default.

variable "proxmox_endpoint" {
  description = "URL of the Proxmox VE API (e.g. https://10.0.10.11:8006/)"
  type        = string
}

variable "key_vault_name" {
  description = "Name of the Azure Key Vault holding this layer's secrets"
  type        = string
}

variable "key_vault_resource_group_name" {
  description = "Resource group containing key_vault_name"
  type        = string
}

variable "proxmox_insecure" {
  description = "Skip TLS verification for the Proxmox API (true if using a self-signed cert)"
  type        = bool
}

variable "talos_version" {
  description = "Talos Linux version for the Image Factory schematic and node images (pin; bump deliberately)"
  type        = string
}

variable "nodes" {
  description = "Combined control-plane/worker nodes (documentation/networking/allocations.md). Key = VM/host name."
  type = map(object({
    pve_node   = string # Proxmox host that runs this VM (pve1/pve2/pve3)
    vm_id      = number
    ip         = string # eth0, VLAN 11 Workloads (static; VLAN has no DHCP)
    storage_ip = string # eth1, VLAN 12 Storage (static, no gateway -- L2-only island)
  }))
}

variable "workloads_gateway" {
  description = "Default gateway on VLAN 11 (router sub-interface)"
  type        = string
}

variable "workloads_vlan_id" {
  description = "VLAN tag for the Workloads network (eth0)"
  type        = number
}

variable "storage_vlan_id" {
  description = "VLAN tag for the Storage/Longhorn network (eth1)"
  type        = number
}

variable "network_bridge" {
  description = "Proxmox bridge carrying the VLAN trunk"
  type        = string
}

variable "image_datastore_id" {
  description = "Datastore for the downloaded Talos nocloud image (must allow ISO/import content)"
  type        = string
}

variable "vm_datastore_id" {
  description = "Datastore for VM disks"
  type        = string
}

variable "vm_cores" {
  description = "vCPU cores per node"
  type        = number
}

variable "vm_memory_mb" {
  description = "RAM per node in MiB. Note: Talos config reserves 2 GiB hugepages per node for the Longhorn v2 engine."
  type        = number
}

variable "local_storage_content" {
  description = "Content types on the `local` dir storage. Proxmox default is backup+iso+vztmpl; `iso` is required for the Talos image download. This list REPLACES the live config -- reconcile before applying (see storage.tf)."
  type        = set(string)
}

variable "vm_disk_gb" {
  description = "OS disk size per node in GiB (Longhorn data shares this disk at /var/lib/longhorn)"
  type        = number
}

variable "storage_mtu" {
  description = "MTU for the VLAN 12 storage NIC (eth1). allocations.md: jumbo frames end-to-end -- the pve hosts' bridge and the switch ports must also be >= this, which is manual host/switch config outside Terraform."
  type        = number
}

variable "core_infra" {
  description = "DNS/NTP LXCs on VLAN 10 (allocations.md). Key = container hostname; sorted key order = resolver order (primary first)."
  type = map(object({
    pve_node = string # Proxmox host that runs this LXC (split across hosts for redundancy)
    ct_id    = number
    ip       = string # static VLAN 10 address
  }))
}

variable "mgmt_vlan_id" {
  description = "VLAN tag for the Shared Infrastructure Mgmt network"
  type        = number
}

variable "mgmt_gateway" {
  description = "Default gateway on VLAN 10 (router)"
  type        = string
}

variable "debian_template_url" {
  description = "Debian LXC template for the core-infra containers"
  type        = string
}

variable "core_infra_ssh_public_key" {
  description = "SSH public key for root in the core-infra LXCs (Technitium/chrony install happens over SSH)"
  type        = string
}

variable "core_infra_cores" {
  description = "vCPU cores per core-infra LXC"
  type        = number
}

variable "core_infra_memory_mb" {
  description = "RAM per core-infra LXC in MiB"
  type        = number
}

variable "core_infra_disk_gb" {
  description = "Root disk size per core-infra LXC in GiB"
  type        = number
}

# -----------------------------------------------------------------------
# Firewall (documentation/networking/firewall_rules.yaml, layer 2)
# -----------------------------------------------------------------------

variable "firewall_cluster_options" {
  description = "Datacenter firewall options. See modules/firewall for shape."
  type = object({
    enabled       = bool
    input_policy  = string
    output_policy = string
  })
}

variable "firewall_ipsets" {
  description = "Cluster-level IPSets (address groups). See modules/firewall for shape."
  type = map(object({
    name    = string
    comment = optional(string)
    members = list(string)
  }))
}

variable "firewall_security_groups" {
  description = "Security groups attached to guest vNICs. See modules/firewall for shape."
  type = map(object({
    name    = string
    comment = optional(string)
    rules = list(object({
      comment = optional(string)
      type    = string
      action  = string
      source  = optional(string)
      dest    = optional(string)
      proto   = optional(string)
      dport   = optional(string)
      sport   = optional(string)
      macro   = optional(string)
    }))
  }))
}

variable "firewall_cluster_rules" {
  description = "Datacenter-level rules, ORDERED (position = evaluation order). Comment each entry with its firewall_rules.yaml ID."
  type = list(object({
    comment = optional(string)
    type    = string
    action  = string
    source  = optional(string)
    dest    = optional(string)
    proto   = optional(string)
    dport   = optional(string)
    sport   = optional(string)
    macro   = optional(string)
  }))
}

variable "core_infra_security_groups" {
  description = "Keys into firewall_security_groups to attach to every core-infra LXC vNIC, in order."
  type        = list(string)
}
