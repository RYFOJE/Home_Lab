# Hardware Inventory

Physical equipment in the homelab. IPs from `../networking/allocations.md`; cabling and
port assignments from `../networking/physical_network.md`.

| Qty | Device | Model | Role | Ports / NICs | Mgmt IP |
|---|---|---|---|---|---|
| 1 | Gateway / Controller | UniFi UCG Fiber | Router (all VLAN gateways), UniFi Network controller, WAN edge | WAN: 1x 10G SFP+, 1x 10GbE RJ45. LAN: 1x 10G SFP+ (uplink to switch), 4x 2.5GbE RJ45 (unused) | 10.0.10.1 |
| 1 | Switch | UniFi USW Pro Max 16 PoE | L2 VLAN trunk (L3 features unused by design) | 12x 1GbE RJ45 PoE+, 4x 2.5GbE RJ45 PoE++, 2x 10G SFP+; 180W PoE budget | 10.0.10.2 |
| 1 | Access Point | UniFi U7 Lite | Wi-Fi 7 AP; SSIDs for VLANs 10, 13, 15 | 1x 2.5GbE RJ45 (PoE-powered, ~13W) | 10.0.10.6 |
| 2 | Hypervisor | Dell OptiPlex 5060 | Proxmox VE: pve1, pve2 | 1x onboard 1GbE (Intel i219) -- all VLANs on one trunk | 10.0.10.11, 10.0.10.12 |
| 1 | Hypervisor | Dell OptiPlex 3070 | Proxmox VE: pve3 | 1x onboard 1GbE (Intel i219) -- all VLANs on one trunk | 10.0.10.13 |
| 1 | Backup Server | TBD (not yet acquired) | Proxmox Backup Server | TBD | 10.0.10.3 (reserved) |
