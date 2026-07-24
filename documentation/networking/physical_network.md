# Physical Network: Cabling, Port Map, and Bootstrap

Physical layer for the equipment in `../infrastructure/inventory.md`. Logical addressing
lives in `allocations.md`; traffic policy in `firewall_rules.yaml`; SSIDs in
`wifi_and_isolation.md`. The switch port map here is mirrored 1:1 by
`terraform/10-network/terraform.tfvars` (`port_profiles` / `devices`) -- keep both in sync.

## Cabling

One row per cable. "Native" = untagged VLAN on that link; "Tagged" = 802.1Q VLANs carried.

| # | From (device / port) | To (device / port) | Media | Link speed | PoE | Native VLAN | Tagged VLANs | Purpose |
|---|---|---|---|---|---|---|---|---|
| 1 | ISP handoff | UCG Fiber / WAN (SFP+ or 10GbE RJ45, per ISP) | per ISP | per ISP | - | - | - | Internet uplink |
| 2 | UCG Fiber / LAN SFP+ | Switch / port 17 (SFP+) | 10G DAC | 10G | - | 10 | 11, 13, 15 | Router-on-a-stick trunk: all inter-VLAN traffic |
| 3 | Switch / port 13 (2.5GbE) | pve1 / onboard NIC | Cat6 | 1G (NIC-limited; port is 2.5G-capable) | off | 10 | 11, 12 | pve1 mgmt + VM trunk |
| 4 | Switch / port 14 (2.5GbE) | pve2 / onboard NIC | Cat6 | 1G (NIC-limited; port is 2.5G-capable) | off | 10 | 11, 12 | pve2 mgmt + VM trunk |
| 5 | Switch / port 15 (2.5GbE) | pve3 / onboard NIC | Cat6 | 1G (NIC-limited; port is 2.5G-capable) | off | 10 | 11, 12 | pve3 mgmt + VM trunk |
| 6 | Switch / port 16 (2.5GbE PoE++) | U7 Lite / uplink | Cat6 | 2.5G | PoE (~13W) | 10 | 13, 15 | AP power + SSID trunk |
| 7 | Switch / port 1 (1GbE) | PBS / NIC | Cat6 | 1G | off | 10 | - | Backup server |
| 8 | Switch / port 2 (1GbE) | Wired admin workstation | Cat6 | 1G | off | 10 | - | Administration (Proxmox/PBS UIs, SSH, kubectl) |
| 9 | Switch / port 3 (1GbE) | Wired trusted device | Cat6 | 1G | off | 13 | - | Trusted device (same policy as `home` SSID) |

VLAN 12 (storage) exists only on cables 3-5 as a tagged VLAN between the pve hosts -- it
never touches the uplink usefully (no router sub-interface exists; frames to the router
die there). Ports 4-12 and 18 are disabled; the UCG Fiber's four LAN RJ45 ports are unused.

## Switch Port Map (USW Pro Max 16 PoE)

Ports 1-12: 1GbE PoE+. Ports 13-16: 2.5GbE PoE++. Ports 17-18: 10G SFP+.

| Port | Profile (Terraform key) | Native | Tagged | PoE | Connected device |
|---|---|---|---|---|---|
| 1 | `access_mgmt` | 10 | - | off | PBS |
| 2 | `access_mgmt` | 10 | - | off | Wired admin workstation |
| 3 | `access_trusted` | 13 | - | off | Wired trusted device |
| 4-12 | `disabled` | - | - | off | - |
| 13 | `trunk_pve` | 10 | 11, 12 | off | pve1 |
| 14 | `trunk_pve` | 10 | 11, 12 | off | pve2 |
| 15 | `trunk_pve` | 10 | 11, 12 | off | pve3 |
| 16 | `trunk_ap` | 10 | 13, 15 | auto | U7 Lite |
| 17 | *(no override)* | 10 | all | - | UCG Fiber LAN SFP+ (10G DAC) |
| 18 | `disabled` | - | - | - | - |

## Decisions

- **Native VLAN on infrastructure ports is VLAN 10 (mgmt).** UniFi devices adopt and are
  managed over the untagged network; native-mgmt means the switch and AP keep management
  connectivity through any partial or failed apply, and factory-reset recovery needs no
  port reconfiguration. Supersedes the earlier native-none design. VLAN 1 remains unused:
  no access port carries it.
- **`mgmt_network_id` is safe by construction.** Terraform sets each device's management
  network to VLAN 10; because VLAN 10 is native on every port a device sits on (and the
  uplink is unrestricted), the documented provider failure mode -- device dropping offline
  when its mgmt VLAN isn't carried on its upstream port -- cannot occur.
- **Uplink port 17 has no port profile override.** It must carry every VLAN; restricting
  the port the switch is managed through risks severing management. It stays on the
  controller's default all-VLAN behaviour.
- **The switch runs L2-only.** The Pro Max 16 PoE is L3-capable; deliberately unused --
  the router owns every gateway (`allocations.md`, "Trunk-based routing"). No DHCP,
  static routes, or inter-VLAN routing are configured on the switch.
- **pve trunks carry only VLANs 10 (native), 11, 12.** No VMs exist on 13/15; VLAN 15
  rides only the AP trunk.

## MTU 9000 Configuration Points (VLAN 12)

Jumbo frames must match end-to-end on the storage VLAN (`allocations.md` design notes).
Where each hop is configured:

| Hop | Setting | Configured by |
|---|---|---|
| Switch | `jumboframe_enabled = true` (switch-wide max-frame raise; VLANs at MTU 1500 are unaffected) | `terraform/10-network` (`devices.switch`) |
| Proxmox bridge / VLAN 12 interface on each pve host | MTU 9000 | `terraform/20-proxmox` |
| k8s VM eth1 | MTU 9000 | `terraform/30-talos` (machine config) |

The router needs nothing: VLAN 12 has no router sub-interface.

## Bootstrap: Manual Steps to a Terraformable State

One-time click-ops, in order. Steps 1-6 cannot be automated; everything after is Terraform.

1. **Cable** per the cabling table. (Switch and AP may also be cabled after step 5.)
2. **UCG Fiber first boot**: connect a laptop to a UCG LAN RJ45 port, open
   `https://192.168.1.1`. In the wizard: set country/timezone, set console name, create
   the local admin account, skip/decline auto network setup where offered. A Ubiquiti
   cloud account is optional; Terraform never uses it.
3. **Create the Terraform admin**: Settings > Admins & Users > add a dedicated **local**
   admin (Network app, Full Management role).
4. **Store secrets in Key Vault** (`az login` first):
   - `az keyvault secret set --vault-name rj-london --name unifi-password --value <terraform admin password>`
   - `wlan-passphrase-home`, `wlan-passphrase-home-iot`, `wlan-passphrase-home-mgmt`
     likewise, if not already present.
5. **Terraform pass 1** (laptop still on the UCG's default LAN):
   `cd terraform/10-network && terraform init && terraform apply`.
   Creates VLANs, SSIDs, port profiles, firewall groups/rules. Device resources are
   skipped automatically (their `mac` values are null). If `10.0.10.1` is not yet
   reachable, run with `-var 'unifi_api_url=https://192.168.1.1/'`; once VLAN 10 exists
   and the console answers on `10.0.10.1`, drop the override.
6. **Adopt devices** in the controller UI: the switch appears once cabled (uplink or any
   UCG LAN port) -- adopt it, wait until online; the AP powers up from switch PoE --
   adopt it. Record from the UI:
   - MAC addresses of the UCG, switch, and AP (device > Overview), and
   - the default user group ID (Settings > Profiles > User Groups > Default; the ID is
     in the browser URL).
7. **Fill in `terraform.tfvars`**: the three `mac` values and `user_group_id`.
8. **Terraform pass 2**: `terraform apply`. Devices receive static IPs, port profiles,
   management network, and jumbo frames.
9. **Post-checks**: switch answers on `10.0.10.2`, AP on `10.0.10.6`, all three SSIDs
   broadcast, disabled ports show no link. Jumbo path check once 20-proxmox is applied:
   `ping -M do -s 8972 10.1.12.12` from a pve host's VLAN 12 interface.
10. **Controller housekeeping** (UI-only, not Terraform-managed): enable auto-backup of
    the controller config (System > Backups), and leave firmware updates manual --
    apply them from the UI during maintenance windows.

## Steady State

The two-pass split exists only because MACs do not exist before adoption. After pass 2
the layer is fully idempotent: a single `terraform plan` / `apply` reconciles everything,
and no recurring manual steps remain except:

- **Hardware replacement or addition**: adopt the new device in the UI, update its `mac`
  in `terraform.tfvars`, apply.
- **Terraform admin password rotation**: change in the UI, update the `unifi-password`
  Key Vault secret.
- **Firmware updates and controller backups**: UI-managed (step 10 above); outside
  Terraform's scope.
