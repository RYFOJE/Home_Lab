# Non-secret configuration for the 20-proxmox layer. Safe to commit.
# Secret (proxmox-api-token) lives in Azure Key Vault, read via
# data.azurerm_key_vault_secret in main.tf.

proxmox_endpoint = "https://10.0.10.11:8006/"
proxmox_insecure = true

key_vault_name                = "rj-london"
key_vault_resource_group_name = "terraform"

# SSH public key for root in the core-infra DNS/NTP LXCs.
core_infra_ssh_public_key = "ssh-ed25519 AAAA... you@machine" # PLACEHOLDER: set before applying

# -----------------------------------------------------------------------
# Talos nodes (documentation/networking/allocations.md)
# -----------------------------------------------------------------------
talos_version = "v1.13.6"

nodes = {
  k8s-node-1 = { pve_node = "pve1", vm_id = 111, ip = "10.1.11.11", storage_ip = "10.1.12.11" }
  k8s-node-2 = { pve_node = "pve2", vm_id = 112, ip = "10.1.11.12", storage_ip = "10.1.12.12" }
  k8s-node-3 = { pve_node = "pve3", vm_id = 113, ip = "10.1.11.13", storage_ip = "10.1.12.13" }
}

workloads_gateway = "10.1.11.1"
workloads_vlan_id = 11
storage_vlan_id   = 12
storage_mtu       = 9000 # jumbo frames end-to-end -- bridge + switch ports must match (manual)

network_bridge     = "vmbr0"
image_datastore_id = "local" # must accept ISO/import content
vm_datastore_id    = "local-lvm"

vm_cores     = 4
vm_memory_mb = 16384 # 2 GiB reserved as hugepages by 30-talos (Longhorn v2 engine)
vm_disk_gb   = 100

local_storage_content = ["backup", "iso", "snippets", "vztmpl"]

# -----------------------------------------------------------------------
# core-infra DNS/NTP LXCs (allocations.md: .4 primary, .5 secondary)
# -----------------------------------------------------------------------
core_infra = {
  core-infra-1 = { pve_node = "pve1", ct_id = 104, ip = "10.0.10.4" }
  core-infra-2 = { pve_node = "pve2", ct_id = 105, ip = "10.0.10.5" }
}

mgmt_vlan_id = 10
mgmt_gateway = "10.0.10.1"

debian_template_url = "http://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst"

core_infra_cores     = 2
core_infra_memory_mb = 1024
core_infra_disk_gb   = 8

# -----------------------------------------------------------------------
# Firewall (documentation/networking/firewall_rules.yaml, layer 2)
#
# SCOPE: PVE-FW-* and LXC-FW-* rules only -- router rules (FW-*) live in
# 10-network. PBS (10.0.10.3) is a standalone box outside this cluster, so
# the bpg provider cannot touch its firewall. Manual on PBS itself:
#   PVE-FW-004 (pve hosts -> 8007), PVE-FW-005 (VLAN 10 -> 8007),
#   PVE-FW-006 (icmp, PBS part), PVE-FW-007 (k8s nodes -> 2049),
#   PVE-FW-008 (deny VLAN 11, PBS part).
# PVE-FW-004 outbound side needs no rule here: output_policy is ACCEPT.
#
# PVE's firewall is stateful (established/related auto-accepted) and
# auto-allows the management ports (8006/22/corosync) from the local cluster
# network -- PVE-FW-001/002/003 are still modeled explicitly per the doc.
#
# LOCKOUT WARNING: cluster_options.enabled=true with input_policy DROP.
# Apply from a VLAN 10 address (PVE-FW-002 is what keeps the API reachable);
# the module sequences the enable after all rules exist.
# -----------------------------------------------------------------------

firewall_cluster_options = {
  enabled       = true
  input_policy  = "DROP" # PVE-FW-900 default-deny-inbound
  output_policy = "ACCEPT"
}

firewall_ipsets = {
  pve_hosts = {
    name    = "pve-hosts"
    comment = "pve1/pve2/pve3 mgmt IPs"
    members = ["10.0.10.11", "10.0.10.12", "10.0.10.13"]
  }
  core_infra = {
    name    = "core-infra"
    comment = "Technitium DNS + chrony LXCs"
    members = ["10.0.10.4", "10.0.10.5"]
  }
  dns_clients = {
    name    = "dns-clients"
    comment = "every population allowed to query DNS (LXC-FW-001)"
    members = ["10.0.10.0/24", "10.1.11.0/24", "10.0.13.0/24", "10.0.15.0/24"]
  }
  ntp_clients = {
    name    = "ntp-clients"
    comment = "same as dns-clients minus VLAN 15 (LXC-FW-002)"
    members = ["10.0.10.0/24", "10.1.11.0/24", "10.0.13.0/24"]
  }
}

# Datacenter rules land on every node's host input chain. Ordered list --
# first match wins, mirroring firewall_rules.yaml.
firewall_cluster_rules = [
  {
    comment = "PVE-FW-001 corosync-cluster-comms"
    type    = "in"
    action  = "ACCEPT"
    source  = "+pve-hosts"
    dest    = "+pve-hosts"
    proto   = "udp"
    dport   = "5405:5412"
  },
  {
    comment = "PVE-FW-002 admin-to-pve-webui"
    type    = "in"
    action  = "ACCEPT"
    source  = "10.0.10.0/24"
    dest    = "+pve-hosts"
    proto   = "tcp"
    dport   = "8006"
  },
  {
    comment = "PVE-FW-003 admin-to-pve-ssh"
    type    = "in"
    action  = "ACCEPT"
    source  = "10.0.10.0/24"
    dest    = "+pve-hosts"
    proto   = "tcp"
    dport   = "22"
  },
  {
    # PBS (10.0.10.3) part of this rule is manual on the PBS box.
    comment = "PVE-FW-006 admin-to-hosts-icmp"
    type    = "in"
    action  = "ACCEPT"
    source  = "10.0.10.0/24"
    dest    = "+pve-hosts"
    macro   = "Ping"
  },
  {
    # Defense-in-depth behind the router's FW-011-equivalent; PBS part manual.
    # PVE-FW-007 (k8s nodes -> PBS 2049) precedes this in the doc but is
    # PBS-side only, so it never appears in this chain.
    comment = "PVE-FW-008 deny-workloads-to-hosts"
    type    = "in"
    action  = "DROP"
    source  = "10.1.11.0/24"
    dest    = "+pve-hosts"
  },
]

# Attached to the core-infra LXC vNICs (firewall=1 -- see core-infra.tf).
# These allows are what keep DNS/NTP alive once the datacenter firewall
# defaults to deny. Macros: DNS = tcp+udp 53, NTP = udp 123, Ping = icmp echo.
firewall_security_groups = {
  core_infra = {
    name    = "core-infra-lxc"
    comment = "LXC-FW-001..005: DNS/NTP/webui/icmp inbound to 10.0.10.4-.5"
    rules = [
      {
        comment = "LXC-FW-001 dns-inbound"
        type    = "in"
        action  = "ACCEPT"
        source  = "+dns-clients"
        macro   = "DNS"
      },
      {
        comment = "LXC-FW-002 ntp-inbound"
        type    = "in"
        action  = "ACCEPT"
        source  = "+ntp-clients"
        macro   = "NTP"
      },
      {
        # Redundant with LXC-FW-001 today; kept explicit so tightening
        # dns-clients later can't silently break zone replication.
        comment = "LXC-FW-003 dns-zone-transfer"
        type    = "in"
        action  = "ACCEPT"
        source  = "+core-infra"
        macro   = "DNS"
      },
      {
        comment = "LXC-FW-004 admin-to-technitium-webui"
        type    = "in"
        action  = "ACCEPT"
        source  = "10.0.10.0/24"
        proto   = "tcp"
        dport   = "5380"
      },
      {
        comment = "LXC-FW-005 admin-to-core-infra-icmp"
        type    = "in"
        action  = "ACCEPT"
        source  = "10.0.10.0/24"
        macro   = "Ping"
      },
    ]
  }
}

core_infra_security_groups = ["core_infra"]
