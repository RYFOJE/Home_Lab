# Non-secret configuration for the 10-network UniFi layer.
# Safe to commit: no passwords or WLAN passphrases live here.
# Secrets (unifi-password, wlan-passphrase-*) live in Azure Key Vault and are
# read at plan/apply time via data.azurerm_key_vault_secret -- see main.tf.
#
# ASSUMPTIONS FLAGGED BELOW ARE UNVERIFIED against the live UniFi controller.
# Run `terraform plan` and reconcile before applying -- do not blind-apply.

key_vault_name                = "rj-london"
key_vault_resource_group_name = "terraform"

unifi_api_url  = "https://10.1.10.1/" # PLACEHOLDER: confirm controller URL (UDM/CloudKey IP)
unifi_username = "ryfoje"          # PLACEHOLDER: local controller user created for Terraform

# -----------------------------------------------------------------------
# VLANs (documentation/networking/allocations.md)
# -----------------------------------------------------------------------
networks = {
  mgmt = {
    name         = "Mgmt"
    vlan         = 10
    subnet       = "10.0.10.0/24"
    dhcp_enabled = false # PLACEHOLDER: no DHCP pool documented for VLAN 10 (all hosts static); flip true + set start/stop if needed
  }
  workloads = {
    name         = "Workloads"
    vlan         = 11
    subnet       = "10.1.11.0/24"
    dhcp_enabled = false # k8s nodes, kube-vip VIP, MetalLB pool are all statically assigned
  }
  storage = {
    name         = "Storage"
    vlan         = 12
    subnet       = "10.1.12.0/24"
    dhcp_enabled = false
    # TODO: allocations.md specifies this VLAN has NO router sub-interface / no gateway
    # (isolated L2 island). Verify how to express that with this provider -- the
    # unifi_network resource may need a different `purpose` or routing setting to
    # avoid creating a gateway automatically. Not yet confirmed against the schema.
  }
  trusted = {
    name         = "Trusted Devices"
    vlan         = 13
    subnet       = "10.0.13.0/24"
    dhcp_enabled = true
    dhcp_start   = "10.0.13.100"
    dhcp_stop    = "10.0.13.199"
  }
  iot = {
    name         = "IoT Devices"
    vlan         = 15
    subnet       = "10.0.15.0/24"
    dhcp_enabled = true
    dhcp_start   = "10.0.15.100"
    dhcp_stop    = "10.0.15.199"
  }
}

# -----------------------------------------------------------------------
# SSIDs (documentation/networking/wifi_and_isolation.md)
# Passphrases are NOT here -- read from Azure Key Vault secrets
# wlan-passphrase-home, wlan-passphrase-home-iot, wlan-passphrase-home-mgmt.
# -----------------------------------------------------------------------
wlan_configs = {
  home = {
    name             = "home"
    vlan             = 13
    user_group_id    = "PLACEHOLDER_default_user_group_id" # TODO: look up in controller: Settings > Profiles > User Groups > Default
    security         = "wpapsk"
    wpa3_support     = true
    wpa3_transition  = true
    client_isolation = false
  }
  home_iot = {
    name             = "home-iot"
    vlan             = 15
    user_group_id    = "PLACEHOLDER_default_user_group_id"
    security         = "wpapsk"
    wpa3_support     = false
    wpa3_transition  = false
    client_isolation = true
  }
  home_mgmt = {
    name             = "home-mgmt"
    vlan             = 10
    user_group_id    = "PLACEHOLDER_default_user_group_id"
    security         = "wpapsk"
    wpa3_support     = true
    wpa3_transition  = false
    client_isolation = false
  }
}

# -----------------------------------------------------------------------
# Firewall (documentation/networking/firewall_rules.yaml)
#
# SCOPE: only router-layer rules (FW-001..FW-021, FW-900) are modeled here.
# The PVE-FW-* and LXC-FW-* rules run on Proxmox's own firewall, not UniFi --
# out of scope for this module.
#
# NOT MODELED, and why:
#   FW-017 (wan-dnat-to-yarp)   -- this is a port-forward/DNAT, not a plain
#                                  firewall rule. Needs a `unifi_port_forward`
#                                  resource instead. TODO: add it.
#   FW-021 (deny-vlan1)         -- VLAN 1 is deliberately left unconfigured
#                                  (no network object exists to reference).
#                                  Structural/manual only.
#   FW-900 (default-deny)       -- assumed covered by each ruleset's default
#                                  policy in the controller (Settings >
#                                  Firewall & Security). TODO: verify.
#
# UNVERIFIED ASSUMPTIONS (check against the provider schema / a plan before applying):
#   - `ruleset` values (LAN_IN / LAN_LOCAL / WAN_OUT) are a best guess at how
#     UniFi zones this rule set; may need adjustment.
#   - `protocol = "tcp_udp"` assumed to be a valid combined value.
#   - FW-004/FW-009 destination is the MetalLB pool 10.1.11.50-10.1.11.249,
#     which doesn't cleanly express as a CIDR. Approximated here as the whole
#     10.1.11.0/24 subnet -- looser than the source doc. Tighten once you
#     confirm how this provider models IP ranges (likely an address-group
#     listing each IP, or it may not support ranges at all).
#   - `rule_index` values are placeholders in the 2000s (LAN) / 3000s (WAN OUT)
#     ranges per UniFi convention -- verify they don't collide with existing
#     manual rules on the controller before applying.
# -----------------------------------------------------------------------

firewall_address_groups = {
  dns_ntp = {
    name    = "dns-ntp-servers"
    members = ["10.0.10.4", "10.0.10.5"]
  }
  k8s_nodes = {
    name    = "k8s-node-ips"
    members = ["10.1.11.11", "10.1.11.12", "10.1.11.13"]
  }
  private_ranges = {
    name    = "private-ranges"
    members = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }
}

firewall_port_groups = {}

firewall_rules = {
  "FW-001" = {
    name                  = "workloads-to-dns"
    action                = "accept"
    ruleset               = "LAN_IN"
    rule_index            = 2001
    protocol              = "tcp_udp"
    src_address           = "10.1.11.0/24"
    dst_address_group_key = "dns_ntp"
    dst_port              = "53"
  }
  "FW-002" = {
    name                  = "workloads-to-ntp"
    action                = "accept"
    ruleset               = "LAN_IN"
    rule_index            = 2002
    protocol              = "udp"
    src_address           = "10.1.11.0/24"
    dst_address_group_key = "dns_ntp"
    dst_port              = "123"
  }
  "FW-003" = {
    name        = "admin-to-kube-api"
    action      = "accept"
    ruleset     = "LAN_IN"
    rule_index  = 2003
    protocol    = "tcp"
    src_address = "10.0.10.0/24"
    dst_address = "10.1.11.10"
    dst_port    = "6443"
  }
  "FW-004" = {
    name        = "admin-to-ingress-and-apps"
    action      = "accept"
    ruleset     = "LAN_IN"
    rule_index  = 2004
    protocol    = "tcp"
    src_address = "10.0.10.0/24"
    dst_address = "10.1.11.0/24" # approximated -- see header note re: MetalLB pool range
    dst_port    = "80,443"
  }
  "FW-005" = {
    name        = "admin-to-workloads-icmp"
    action      = "accept"
    ruleset     = "LAN_IN"
    rule_index  = 2005
    protocol    = "icmp"
    src_address = "10.0.10.0/24"
    dst_address = "10.1.11.0/24"
  }
  "FW-006" = {
    name        = "admin-to-router-mgmt"
    action      = "accept"
    ruleset     = "LAN_LOCAL"
    rule_index  = 2006
    protocol    = "tcp"
    src_address = "10.0.10.0/24"
    dst_address = "10.0.10.1"
    dst_port    = "443,22"
  }
  "FW-007" = {
    name                  = "trusted-to-dns"
    action                = "accept"
    ruleset               = "LAN_IN"
    rule_index            = 2007
    protocol              = "tcp_udp"
    src_address           = "10.0.13.0/24"
    dst_address_group_key = "dns_ntp"
    dst_port              = "53"
  }
  "FW-008" = {
    name                  = "trusted-to-ntp"
    action                = "accept"
    ruleset               = "LAN_IN"
    rule_index            = 2008
    protocol              = "udp"
    src_address           = "10.0.13.0/24"
    dst_address_group_key = "dns_ntp"
    dst_port              = "123"
  }
  "FW-009" = {
    name        = "trusted-to-ingress-and-apps"
    action      = "accept"
    ruleset     = "LAN_IN"
    rule_index  = 2009
    protocol    = "tcp"
    src_address = "10.0.13.0/24"
    dst_address = "10.1.11.0/24" # approximated -- see header note re: MetalLB pool range
    dst_port    = "80,443"
  }
  "FW-010" = {
    name        = "trusted-to-kube-api"
    action      = "accept"
    ruleset     = "LAN_IN"
    rule_index  = 2010
    protocol    = "tcp"
    src_address = "10.0.13.0/24"
    dst_address = "10.1.11.10"
    dst_port    = "6443"
  }
  "FW-011" = {
    name                  = "deny-trusted-to-private"
    action                = "drop"
    ruleset               = "LAN_IN"
    rule_index            = 2011
    protocol              = "all"
    src_address           = "10.0.13.0/24"
    dst_address_group_key = "private_ranges"
  }
  "FW-012" = {
    name        = "trusted-to-internet"
    action      = "accept"
    ruleset     = "WAN_OUT"
    rule_index  = 3001
    protocol    = "all"
    src_address = "10.0.13.0/24"
    # dst intentionally unset = any/internet
  }
  "FW-013" = {
    name                  = "core-infra-upstream"
    action                = "accept"
    ruleset               = "WAN_OUT"
    rule_index            = 3002
    protocol              = "tcp_udp"
    src_address_group_key = "dns_ntp"
    dst_port              = "53,123,443"
  }
  "FW-014" = {
    name        = "mgmt-to-internet"
    action      = "accept"
    ruleset     = "WAN_OUT"
    rule_index  = 3003
    protocol    = "tcp"
    src_address = "10.0.10.0/24"
    dst_port    = "80,443"
  }
  "FW-015" = {
    name        = "workloads-to-internet"
    action      = "accept"
    ruleset     = "WAN_OUT"
    rule_index  = 3004
    protocol    = "tcp"
    src_address = "10.1.11.0/24"
    dst_port    = "80,443"
  }
  "FW-016" = {
    name                  = "workloads-to-longhorn-backup"
    action                = "accept"
    ruleset               = "LAN_IN"
    rule_index            = 2012
    protocol              = "tcp"
    src_address_group_key = "k8s_nodes"
    dst_address           = "10.0.10.3"
    dst_port              = "2049"
  }
  "FW-018" = {
    name                  = "iot-to-dns"
    action                = "accept"
    ruleset               = "LAN_IN"
    rule_index            = 2013
    protocol              = "tcp_udp"
    src_address           = "10.0.15.0/24"
    dst_address_group_key = "dns_ntp"
    dst_port              = "53"
  }
  "FW-019" = {
    name                  = "deny-iot-to-private"
    action                = "drop"
    ruleset               = "LAN_IN"
    rule_index            = 2014
    protocol              = "all"
    src_address           = "10.0.15.0/24"
    dst_address_group_key = "private_ranges"
  }
  "FW-020" = {
    name        = "iot-to-internet"
    action      = "accept"
    ruleset     = "WAN_OUT"
    rule_index  = 3005
    protocol    = "all"
    src_address = "10.0.15.0/24"
  }
}
