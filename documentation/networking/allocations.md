# Homelab IP Address Plan

Private range in use: `10.0.0.0/8` (RFC1918). Shared infrastructure and Project 1 are kept in
separate address spaces so ownership is unambiguous at a glance.

**Addressing convention (for future projects):** 2nd octet = scope (`0` = shared, `1` = Project 1,
`2` = Project 2, ...); 3rd octet = VLAN ID. E.g. a future Project 2 workloads VLAN would be
VLAN 21 -> `10.2.21.0/24`, keeping the scheme self-describing as more projects are added.
VLAN 13 (Trusted Devices) is shared scope, hence `10.0.13.0/24`.

## Address Assignments

| Device / Resource | Type | VLAN | Scope | IP Address | Description |
|---|---|---|---|---|---|
| Router | Network Device | VLAN 10 | Shared | 10.0.10.1 | Shared gateway - multi-project, not owned by Project 1 |
| Switch | Network Device | VLAN 10 | Shared | 10.0.10.2 | Shared VLAN trunk mgmt IP (L2 only - does not route) |
| Proxmox Backup Server | Server | VLAN 10 | Shared | 10.0.10.3 | Backs up VMs/CTs across all projects |
| DNS + NTP (core-infra-1, Primary) | LXC (on pve1) | VLAN 10 | Shared | 10.0.10.4 | Primary Technitium DNS (authoritative for `home.arpa`, recursive resolver) + chrony (internal NTP source) |
| DNS + NTP (core-infra-2, Secondary) | LXC (on pve2) | VLAN 10 | Shared | 10.0.10.5 | Secondary Technitium DNS (zone transfer from primary) + independent chrony instance |
| Wireless Access Point (mgmt) | Network Device | VLAN 10 | Shared | 10.0.10.6 | AP management interface; broadcasts SSIDs for VLANs 10, 13, 15 (see `wifi_and_isolation.md`) |
| pve1 (mgmt) | Hypervisor Host | VLAN 10 | Shared | 10.0.10.11 | Shared hypervisor - hosts VMs for multiple projects |
| pve2 (mgmt) | Hypervisor Host | VLAN 10 | Shared | 10.0.10.12 | Shared hypervisor - hosts VMs for multiple projects |
| pve3 (mgmt) | Hypervisor Host | VLAN 10 | Shared | 10.0.10.13 | Shared hypervisor - hosts VMs for multiple projects |
| Router (VLAN 11 sub-if) | Network Device | VLAN 11 | Shared, routes for Project 1 | 10.1.11.1 | Trunk sub-interface gateway for the Workloads VLAN |
| Router (VLAN 13 sub-if) | Network Device | VLAN 13 | Shared | 10.0.13.1 | Trunk sub-interface gateway for the Trusted Devices VLAN |
| Router (VLAN 15 sub-if) | Network Device | VLAN 15 | Shared | 10.0.15.1 | Trunk sub-interface gateway for the IoT VLAN |
| Device adoption DHCP pool | DHCP Pool | VLAN 10 | Shared | 10.0.10.200 - 10.0.10.249 | Temporary addresses for UniFi device adoption; all infrastructure is static below .200 |
| Trusted device DHCP pool | DHCP Pool | VLAN 13 | Shared | 10.0.13.100 - 10.0.13.199 | Personal laptops/phones/workstations; DHCP-assigned |
| IoT device DHCP pool | DHCP Pool | VLAN 15 | Shared | 10.0.15.100 - 10.0.15.199 | Smart-home devices on the `home-iot` SSID; DHCP-assigned |
| Kubernetes API VIP (Talos-native) | Virtual IP | VLAN 11 | Project 1 | 10.1.11.10 | Floats across the 3 combined control-plane/worker nodes; managed by Talos |
| k8s-node-1 (eth0) | VM - Talos Node | VLAN 11 | Project 1 | 10.1.11.11 | Combined control-plane + worker; runs on pve1 |
| k8s-node-2 (eth0) | VM - Talos Node | VLAN 11 | Project 1 | 10.1.11.12 | Combined control-plane + worker; runs on pve2 |
| k8s-node-3 (eth0) | VM - Talos Node | VLAN 11 | Project 1 | 10.1.11.13 | Combined control-plane + worker; runs on pve3 |
| MetalLB Pool | LoadBalancer Pool | VLAN 11 | Project 1 | 10.1.11.50 - 10.1.11.249 | Pool for LoadBalancer-type Services (e.g. ingress-nginx); 200 addresses |
| YARP edge proxy | LoadBalancer Service | VLAN 11 | Project 1 | 10.1.11.50 | Public reverse proxy running in-cluster; pinned first pool IP; sole WAN DNAT target (80/443). See `wifi_and_isolation.md` |
| k8s-node-1 (eth1) | VM - Storage NIC | VLAN 12 | Project 1 | 10.1.12.11 | Dedicated Longhorn interface; same VM as k8s-node-1. **No gateway configured** (see design notes) |
| k8s-node-2 (eth1) | VM - Storage NIC | VLAN 12 | Project 1 | 10.1.12.12 | Dedicated Longhorn interface; same VM as k8s-node-2. **No gateway configured** (see design notes) |
| k8s-node-3 (eth1) | VM - Storage NIC | VLAN 12 | Project 1 | 10.1.12.13 | Dedicated Longhorn interface; same VM as k8s-node-3. **No gateway configured** (see design notes) |

## VLAN / Subnet Ranges

| VLAN ID | Name | Scope | CIDR | Gateway | Usable Hosts | Purpose |
|---|---|---|---|---|---|---|
| VLAN 1 | *(unused - default/native VLAN, intentionally left untagged)* | - | - | - | - | Not used for any traffic, to reduce VLAN-hopping exposure |
| VLAN 10 | Shared Infrastructure Mgmt | Shared (multi-project) | 10.0.10.0/24 | 10.0.10.1 | 254 | Proxmox host mgmt, PBS, router/switch mgmt, corosync |
| VLAN 11 | Kubernetes / Workloads | Project 1 | 10.1.11.0/24 | 10.1.11.1 (router sub-if) | 254 | Talos node primary interfaces, Talos-native API VIP, MetalLB pool |
| VLAN 12 | Storage / Longhorn | Project 1 | 10.1.12.0/24 | **none - L2-only, no gateway** | 254 | Dedicated Longhorn replica/engine traffic via Multus storage-network. Isolated L2 island: no router sub-interface, unreachable from other VLANs by construction |
| VLAN 13 | Trusted Devices | Shared (multi-project) | 10.0.13.0/24 | 10.0.13.1 (router sub-if) | 254 | Personal laptops/phones/workstations. Keeps daily-driver devices off the mgmt VLAN; access limited to published services, kube API, DNS/NTP, and the internet (see `firewall_rules.yaml`) |
| VLAN 15 | IoT Devices | Shared (multi-project) | 10.0.15.0/24 | 10.0.15.1 (router sub-if) | 254 | Smart-home devices via the `home-iot` SSID. Internet + internal DNS only; no path to published apps, the kube API, or any other VLAN (see `wifi_and_isolation.md`) |

## Kubernetes Overlay (Virtual, not VLAN-tagged)

| Range Name | CIDR | Scope | Purpose | Notes |
|---|---|---|---|---|
| Pod CIDR | 10.1.200.0/22 | Project 1 (virtual) | Kubernetes pod-to-pod networking (CNI overlay) | Set via `cluster.network.podSubnets` in the Talos machine config (`terraform/30-talos`); Talos default is `10.244.0.0/16`. **Capacity ceiling:** at the default /24-per-node allocation, a /22 supports a maximum of 4 nodes - the current 3 plus exactly one more. Before adding a 5th node, either widen to /21 (would require redeploying the CNI) or shrink the per-node mask via a `node-cidr-mask-size=25` controller-manager arg. |
| Service CIDR | 10.1.204.0/24 | Project 1 (virtual) | Kubernetes ClusterIP service addresses | Set via `cluster.network.serviceSubnets` in the Talos machine config (`terraform/30-talos`); Talos default is `10.96.0.0/12`. |

## Design Notes

- **VLAN 1 avoided:** left unused rather than carrying shared mgmt traffic, since VLAN 1 is the
  default/native VLAN on most switches and is more exposed to VLAN-hopping attacks. Shared mgmt
  moved to VLAN 10.
- **Corosync on VLAN 10:** sharing the mgmt VLAN with Proxmox corosync is acceptable at this
  scale. Corosync is latency-sensitive; the fallback if cluster instability appears under load
  is a dedicated low-latency link/VLAN.
- **Trunk-based routing:** the switch is L2-only (VLAN trunk); the router holds the actual gateway
  IPs for VLANs 11, 13, and 15 via 802.1Q sub-interfaces (rows above). Left out of
  `network_visualization.md`'s edge list to keep that diagram readable - this table is the source
  of truth for gateway ownership.
- **VLAN 12 is deliberately L2-only (no gateway):** all Longhorn replica/engine traffic is
  node-to-node within the VLAN (eth1 <-> eth1), so a gateway would route nothing legitimate.
  Removing the router sub-interface makes the storage VLAN unreachable from every other VLAN
  *by construction* - isolation no longer depends on router ACLs staying correct. The k8s VMs'
  eth1 interfaces are configured with an IP and netmask only: **no gateway, no default route**
  (a second default route would risk asymmetric routing). Trade-off: storage NICs can't be
  pinged from the mgmt VLAN; diagnosis happens from inside a k8s node, pinging across VLAN 12.
- **Jumbo frames on VLAN 12:** MTU 9000 for Longhorn replica traffic - the isolated L2 segment
  has no path-MTU discovery issues or mixed-MTU neighbors. MTU must match end-to-end: switch
  ports, the Proxmox bridge/VLAN interface on each pve host, and eth1 inside each k8s VM.
  Every other VLAN stays at 1500.
- **Trusted Devices on VLAN 13, not VLAN 10:** personal daily-driver devices (laptops, phones)
  live on their own VLAN rather than the mgmt VLAN, so a compromised or merely-curious personal
  device has no path to Proxmox/PBS/switch mgmt interfaces. VLAN 13 reaches: published apps
  (MetalLB/ingress pool), the kube API (kubectl), internal DNS/NTP, and the internet -
  nothing else. Administrative work (Proxmox web UI, SSH, Technitium admin UI) happens from
  VLAN 10: a wired admin machine or the `home-mgmt` SSID.
- **Public edge is YARP running in-cluster:** the router's only WAN port-forward is tcp
  80/443 to YARP's pinned MetalLB IP (10.1.11.50). Containment of the internet-facing pod is
  handled at the Kubernetes layer (NetworkPolicy, no ServiceAccount token) rather than a
  separate DMZ VLAN. Design and blast-radius analysis in `wifi_and_isolation.md`.
- **VLAN 15 (IoT) keeps untrusted firmware off VLAN 13:** smart-home devices get internet and
  internal DNS (so blocklists apply) and nothing else - unlike trusted devices, they cannot
  reach published apps or the kube API.
- **Wi-Fi carries VLANs 10, 13, 15 (one SSID each); VLANs 11/12 are wired-only.** SSID
  mapping and AP config in `wifi_and_isolation.md`.
- **DNS/NTP placement and redundancy:** runs as two LXCs on VLAN 10 (shared infra), not inside
  the Talos cluster - DNS/NTP are foundational dependencies and shouldn't go down with the cluster,
  or with any single hypervisor. The two instances are deliberately split across different
  Proxmox hosts (pve1, pve2) so losing one host doesn't take down both:
  - DNS: `10.0.10.4` is primary (authoritative for `home.arpa`); `10.0.10.5` is a secondary zone
    pulling updates via zone transfer. Clients list both as resolvers (primary first).
  - NTP: both run independent chrony instances syncing from the public NTP pool - no
    replication needed, clients list both as time sources.
  - The Proxmox hosts and PBS are themselves clients: `/etc/resolv.conf` and chrony on
    pve1/pve2/pve3/PBS point at `10.0.10.4` and `10.0.10.5` (intra-VLAN 10 traffic; the LXC-FW
    rules in `firewall_rules.yaml` are the host-firewall allows that make this work).

  Root domain is `home.arpa` (RFC 8375) for infra hostnames; anything published via ingress
  uses a real owned domain, since `home.arpa` can't get a publicly-trusted TLS cert.
  Non-`home.arpa` queries are forwarded upstream to a public resolver.
- **Backup strategy (PBS + Longhorn split):** PBS backs up VM/CT *system* disks. The k8s VMs'
  Longhorn data disks are **excluded** from PBS backup jobs - Longhorn keeps 3 replicas of every
  volume, so backing up all three VMs whole would store three crash-consistent copies of the
  same data. Instead, Longhorn's built-in backup feature targets an NFSv4 export (or S3/MinIO)
  hosted on the PBS box, giving app-consistent, deduplicated volume backups. Net result: PBS
  holds OS disks + Longhorn's own volume backups, once each. The network path for this
  (k8s node IPs -> PBS tcp 2049) is FW-016 / PVE-FW-007 in `firewall_rules.yaml`.
- **Off-site copy (3-2-1):** PBS alone is one copy in the same room on the same power as
  everything it protects. The 3-2-1 rule is completed by syncing the PBS datastore off-site -
  either a PBS remote (sync job to a second PBS elsewhere) or an encrypted `rclone` push to
  cloud object storage. Fire/theft/ransomware all defeat a single local copy.
- **Firewall rules:** the full rule set required for this network to function - inter-VLAN
  router ACLs plus documented intra-VLAN traffic - lives in `firewall_rules.yaml` next to this
  file, not duplicated here.
- **Physical layer:** cabling, the switch port map, native-VLAN policy, MTU configuration
  points, and the device adoption/bootstrap sequence live in `physical_network.md`.
  Hardware models in `../infrastructure/inventory.md`.
