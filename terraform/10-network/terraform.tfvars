# Non-secret configuration for the 10-network UniFi layer.
# Safe to commit: no passwords or WLAN passphrases live here.
# Secrets (unifi-password, wlan-passphrase-*) live in Azure Key Vault and are
# read at plan/apply time via data.azurerm_key_vault_secret -- see main.tf.
#
# ASSUMPTIONS FLAGGED BELOW ARE UNVERIFIED against the live UniFi controller.
# Run `terraform plan` and reconcile before applying -- do not blind-apply.

key_vault_name                = "rj-london"
key_vault_resource_group_name = "terraform"

# UCG Fiber = gateway + UniFi controller at the router mgmt IP (allocations.md).
# During bootstrap the console still sits on its wizard-default LAN; override with
# -var 'unifi_api_url=https://192.168.1.1/' for pass 1 if 10.0.10.1 is unreachable.
# See documentation/networking/physical_network.md for the bootstrap sequence.
unifi_api_url  = "https://10.0.10.1/"
unifi_username = "ryfoje" # local controller user created for Terraform (bootstrap step 3)

# -----------------------------------------------------------------------
# VLANs (documentation/networking/allocations.md)
# -----------------------------------------------------------------------
networks = {
  mgmt = {
    name         = "Mgmt"
    vlan         = 10
    subnet       = "10.0.10.0/24"
    dhcp_enabled = true # device adoption pool only; all infrastructure is static below .200 (allocations.md)
    dhcp_start   = "10.0.10.200"
    dhcp_stop    = "10.0.10.249"
  }
  workloads = {
    name         = "Workloads"
    vlan         = 11
    subnet       = "10.1.11.0/24"
    dhcp_enabled = false # k8s nodes, control-plane VIP, LB pool (Cilium) are all statically assigned
  }
  storage = {
    name         = "Storage"
    purpose      = "vlan-only" # no gateway sub-interface -- isolated L2 island per allocations.md
    vlan         = 12
    dhcp_enabled = false
    # No subnet: vlan-only networks carry no L3 config. Addressing (10.1.12.0/24)
    # is set statically on the VM NICs by 20-proxmox / 30-talos.
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
    network_key      = "trusted"                           # VLAN 13
    user_group_id    = "PLACEHOLDER_default_user_group_id" # FILL IN during bootstrap: default user group ID (Settings > Profiles > User Groups > Default)
    security         = "wpapsk"
    wpa3_support     = true
    wpa3_transition  = true # WPA3-only, no WPA2 fallback
    client_isolation = false
  }
  home_iot = {
    name             = "home-iot"
    network_key      = "iot" # VLAN 15
    user_group_id    = "PLACEHOLDER_default_user_group_id"
    security         = "wpapsk"
    wpa3_support     = false
    wpa3_transition  = false
    client_isolation = true
    wlan_band        = "2g" # wifi_and_isolation.md: IoT SSID is 2.4 GHz only
  }
  home_mgmt = {
    name             = "home-mgmt"
    network_key      = "mgmt" # VLAN 10
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
# RULESET MODEL: everything lives in LAN_IN as one sequential first-match-wins
# list, mirroring firewall_rules.yaml order. LAN_IN sees all traffic entering
# the router from a LAN VLAN -- both inter-VLAN and internet-bound -- so the
# internet allows sit here too (in WAN_OUT they would be unreachable behind the
# FW-900 drop, since LAN_IN is evaluated first). FW-000 accepts established/
# related up front so the FW-900 drop-all can't break stateful return traffic.
# FW-006 is the sole LAN_LOCAL rule (traffic terminating on the router).
# Deliberately NO drop-all in LAN_LOCAL: it would break DHCP for VLANs 13/15
# and router mgmt; the controller default handles that chain.
#
# NOT MODELED, and why:
#   FW-021 (deny-vlan1)         -- VLAN 1 is deliberately left unconfigured
#                                  (no network object exists to reference).
#                                  Structural/manual only.
#
# REMAINING ASSUMPTIONS (check against a plan before applying):
#   - FW-004/FW-009 destination is the LoadBalancer pool (Cilium LB IPAM)
#     10.1.11.50-10.1.11.249, which doesn't cleanly express as a CIDR.
#     Approximated here as the whole 10.1.11.0/24 subnet -- looser than the
#     source doc. Tighten once you confirm how this provider models IP ranges
#     (likely an address-group listing each IP, or it may not support ranges
#     at all).
#   - `rule_index` values 2000-2999 (user LAN_IN range per UniFi convention) --
#     verify they don't collide with existing manual rules on the controller
#     before applying.
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
  "FW-000" = {
    name              = "allow-established-related"
    action            = "accept"
    ruleset           = "LAN_IN"
    rule_index        = 2000
    protocol          = "all"
    state_established = true
    state_related     = true
    # firewall_rules.yaml: "stateful firewall -- return traffic implied".
    # Must precede FW-900 so replies to allowed flows are never dropped.
  }
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
    dst_address = "10.1.11.0/24" # approximated -- see header note re: LB pool range
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
    dst_address = "10.1.11.0/24" # approximated -- see header note re: LB pool range
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
    ruleset     = "LAN_IN"
    rule_index  = 2012
    protocol    = "all"
    src_address = "10.0.13.0/24"
    # dst unset = anything; safe only because FW-011 (2011) already dropped
    # all RFC1918 space for this source.
  }
  "FW-013" = {
    name                  = "core-infra-upstream"
    action                = "accept"
    ruleset               = "LAN_IN"
    rule_index            = 2013
    protocol              = "tcp_udp"
    src_address_group_key = "dns_ntp"
    dst_port              = "53,123,443"
  }
  "FW-014" = {
    name        = "mgmt-to-internet"
    action      = "accept"
    ruleset     = "LAN_IN"
    rule_index  = 2014
    protocol    = "tcp"
    src_address = "10.0.10.0/24"
    dst_port    = "80,443"
  }
  "FW-015" = {
    name        = "workloads-to-internet"
    action      = "accept"
    ruleset     = "LAN_IN"
    rule_index  = 2015
    protocol    = "tcp"
    src_address = "10.1.11.0/24"
    dst_port    = "80,443"
  }
  "FW-015-quic" = {
    # Second clause of doc rule FW-015 (one doc ID, two entries -- same
    # pattern as FW-017-https/http): cloudflared QUIC to the Cloudflare edge.
    name        = "workloads-to-cloudflared-quic"
    action      = "accept"
    ruleset     = "LAN_IN"
    rule_index  = 2017
    protocol    = "udp"
    src_address = "10.1.11.0/24"
    dst_port    = "7844"
  }
  "FW-016" = {
    name                  = "workloads-to-longhorn-backup"
    action                = "accept"
    ruleset               = "LAN_IN"
    rule_index            = 2016
    protocol              = "tcp"
    src_address_group_key = "k8s_nodes"
    dst_address           = "10.0.10.3"
    dst_port              = "2049"
  }
  "FW-018" = {
    name                  = "iot-to-dns"
    action                = "accept"
    ruleset               = "LAN_IN"
    rule_index            = 2018
    protocol              = "tcp_udp"
    src_address           = "10.0.15.0/24"
    dst_address_group_key = "dns_ntp"
    dst_port              = "53"
  }
  "FW-019" = {
    name                  = "deny-iot-to-private"
    action                = "drop"
    ruleset               = "LAN_IN"
    rule_index            = 2019
    protocol              = "all"
    src_address           = "10.0.15.0/24"
    dst_address_group_key = "private_ranges"
    # Must precede FW-020, same allow/deny/allow pattern as FW-011/012.
  }
  "FW-020" = {
    name        = "iot-to-internet"
    action      = "accept"
    ruleset     = "LAN_IN"
    rule_index  = 2020
    protocol    = "all"
    src_address = "10.0.15.0/24"
  }
  "FW-900" = {
    name       = "default-deny"
    action     = "drop"
    ruleset    = "LAN_IN"
    rule_index = 2900
    protocol   = "all"
    # Final catch-all: anything a LAN VLAN sends at the router that no rule
    # above allowed is dropped. UniFi's LAN_IN default is accept, so without
    # this rule the whole posture is silently allow-by-default.
  }
}

# Public edge mode -- the single source of truth (50-cloudflare reads this via
# remote state). "tunnel": cloudflared carries WAN traffic and the
# port_forwards map below is forced to {} in main.tf; "dnat": the FW-017
# forwards are live. Flip here, then apply 10-network followed by 50-cloudflare.
edge_mode = "dnat" # flip to "tunnel" at cutover, after 50-cloudflare is verified

# FW-017 (firewall_rules.yaml): the dnat-mode fallback WAN entry -- tcp 80/443
# DNAT to the external Traefik instance (10.1.11.50, Cilium LB IPAM). 443
# carries the published apps; 80 exists solely for the HTTP->HTTPS redirect
# (ACME is DNS-01, no inbound dependency). The internal instance (10.1.11.51)
# is never forwarded. In tunnel mode no WAN forward exists at all -- the
# entries stay here as the documented fallback path. The module object takes
# one port per entry, hence two entries.
port_forwards = {
  "FW-017-https" = {
    name         = "wan-dnat-to-traefik-https"
    protocol     = "tcp"
    wan_port     = "443"
    forward_ip   = "10.1.11.50"
    forward_port = "443"
  }
  "FW-017-http" = {
    name         = "wan-dnat-to-traefik-http"
    protocol     = "tcp"
    wan_port     = "80"
    forward_ip   = "10.1.11.50"
    forward_port = "80"
  }
}

# -----------------------------------------------------------------------
# Switch port profiles and devices
# (documentation/networking/physical_network.md is the source of truth for
# the port map, cabling, and the bootstrap/adoption sequence)
# -----------------------------------------------------------------------
port_profiles = {
  # pve host trunks: mgmt untagged (hosts' own traffic + device adoption),
  # workloads + storage tagged for the VM bridges. VLANs 13/15 deliberately
  # not carried -- no VMs live on them.
  trunk_pve = {
    name                = "trunk-pve"
    forward             = "customize"
    native_network_key  = "mgmt"
    tagged_network_keys = ["workloads", "storage"]
    poe_mode            = "off"
  }
  # AP trunk: mgmt untagged (AP adoption/management), SSID VLANs tagged.
  trunk_ap = {
    name                = "trunk-ap"
    forward             = "customize"
    native_network_key  = "mgmt"
    tagged_network_keys = ["trusted", "iot"]
    poe_mode            = "auto"
  }
  access_mgmt = {
    name               = "access-mgmt"
    forward            = "native"
    native_network_key = "mgmt"
    poe_mode           = "off"
  }
  access_trusted = {
    name               = "access-trusted"
    forward            = "native"
    native_network_key = "trusted"
    poe_mode           = "off"
  }
  # Hardening: unused ports carry nothing.
  disabled = {
    name    = "disabled"
    forward = "disabled"
  }
}

devices = {
  # UCG Fiber: gateway + controller. Managed minimally -- its LAN RJ45 ports
  # are unused (inventory.md); all LAN traffic enters via the SFP+ uplink.
  gateway = {
    name = "UCG Fiber"
    mac  = null # FILL IN after adoption (bootstrap step 7)
  }
  # USW Pro Max 16 PoE. Port 17 (SFP+ uplink to the UCG) deliberately has no
  # override: restricting the uplink risks severing switch management.
  switch = {
    name               = "USW Pro Max 16 PoE"
    mac                = null # FILL IN after adoption (bootstrap step 7)
    mgmt_network_key   = "mgmt"
    jumboframe_enabled = true # VLAN 12 Longhorn jumbo frames (MTU 9000, allocations.md)
    static_ip = {
      ip      = "10.0.10.2"
      netmask = "255.255.255.0"
      gateway = "10.0.10.1"
      dns1    = "10.0.10.4"
      dns2    = "10.0.10.5"
    }
    ports = {
      "1"  = "access_mgmt"    # PBS
      "2"  = "access_mgmt"    # wired admin workstation
      "3"  = "access_trusted" # wired trusted device
      "4"  = "disabled"
      "5"  = "disabled"
      "6"  = "disabled"
      "7"  = "disabled"
      "8"  = "disabled"
      "9"  = "disabled"
      "10" = "disabled"
      "11" = "disabled"
      "12" = "disabled"
      "13" = "trunk_pve" # pve1 (2.5GbE -- NIC upgrade headroom)
      "14" = "trunk_pve" # pve2
      "15" = "trunk_pve" # pve3
      "16" = "trunk_ap"  # U7 Lite (PoE)
      # "17" = SFP+ uplink to UCG Fiber -- intentionally no override
      "18" = "disabled" # spare SFP+
    }
  }
  ap = {
    name             = "U7 Lite"
    mac              = null # FILL IN after adoption (bootstrap step 7)
    mgmt_network_key = "mgmt"
    static_ip = {
      ip      = "10.0.10.6"
      netmask = "255.255.255.0"
      gateway = "10.0.10.1"
      dns1    = "10.0.10.4"
      dns2    = "10.0.10.5"
    }
  }
}
