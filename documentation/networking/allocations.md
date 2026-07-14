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
| pve1 (mgmt) | Hypervisor Host | VLAN 10 | Shared | 10.0.10.11 | Shared hypervisor - hosts VMs for multiple projects |
| pve2 (mgmt) | Hypervisor Host | VLAN 10 | Shared | 10.0.10.12 | Shared hypervisor - hosts VMs for multiple projects |
| pve3 (mgmt) | Hypervisor Host | VLAN 10 | Shared | 10.0.10.13 | Shared hypervisor - hosts VMs for multiple projects |
| Router (VLAN 11 sub-if) | Network Device | VLAN 11 | Shared, routes for Project 1 | 10.1.11.1 | Router-on-a-stick gateway for the Workloads VLAN |
| Router (VLAN 13 sub-if) | Network Device | VLAN 13 | Shared | 10.0.13.1 | Router-on-a-stick gateway for the Trusted Devices VLAN |
| Trusted device DHCP pool | DHCP Pool | VLAN 13 | Shared | 10.0.13.100 - 10.0.13.199 | Personal laptops/phones/workstations; DHCP-assigned |
| Kubernetes API VIP (kube-vip) | Virtual IP | VLAN 11 | Project 1 | 10.1.11.10 | Floats across the 3 combined control-plane/worker nodes |
| k8s-node-1 (eth0) | VM - k3s Node | VLAN 11 | Project 1 | 10.1.11.11 | Combined control-plane + worker; runs on pve1 |
| k8s-node-2 (eth0) | VM - k3s Node | VLAN 11 | Project 1 | 10.1.11.12 | Combined control-plane + worker; runs on pve2 |
| k8s-node-3 (eth0) | VM - k3s Node | VLAN 11 | Project 1 | 10.1.11.13 | Combined control-plane + worker; runs on pve3 |
| MetalLB Pool | LoadBalancer Pool | VLAN 11 | Project 1 | 10.1.11.50 - 10.1.11.99 | Pool for LoadBalancer-type Services (e.g. ingress-nginx) |
| k8s-node-1 (eth1) | VM - Storage NIC | VLAN 12 | Project 1 | 10.1.12.11 | Dedicated Longhorn interface; same VM as k8s-node-1. **No gateway configured** (see design notes) |
| k8s-node-2 (eth1) | VM - Storage NIC | VLAN 12 | Project 1 | 10.1.12.12 | Dedicated Longhorn interface; same VM as k8s-node-2. **No gateway configured** (see design notes) |
| k8s-node-3 (eth1) | VM - Storage NIC | VLAN 12 | Project 1 | 10.1.12.13 | Dedicated Longhorn interface; same VM as k8s-node-3. **No gateway configured** (see design notes) |

## VLAN / Subnet Ranges

| VLAN ID | Name | Scope | CIDR | Gateway | Usable Hosts | Purpose |
|---|---|---|---|---|---|---|
| VLAN 1 | *(unused - default/native VLAN, intentionally left untagged)* | - | - | - | - | Not used for any traffic, to reduce VLAN-hopping exposure |
| VLAN 10 | Shared Infrastructure Mgmt | Shared (multi-project) | 10.0.10.0/24 | 10.0.10.1 | 254 | Proxmox host mgmt, PBS, router/switch mgmt, corosync |
| VLAN 11 | Kubernetes / Workloads | Project 1 | 10.1.11.0/24 | 10.1.11.1 (router sub-if) | 254 | k3s node primary interfaces, kube-vip API VIP, MetalLB pool |
| VLAN 12 | Storage / Longhorn | Project 1 | 10.1.12.0/24 | **none - L2-only, no gateway** | 254 | Dedicated Longhorn replica/engine traffic via Multus storage-network. Isolated L2 island: no router sub-interface, unreachable from other VLANs by construction |
| VLAN 13 | Trusted Devices | Shared (multi-project) | 10.0.13.0/24 | 10.0.13.1 (router sub-if) | 254 | Personal laptops/phones/workstations. Keeps daily-driver devices off the mgmt VLAN; access limited to published services, kube API, DNS/NTP, and the internet (see `firewall_rules.yaml`) |

## Kubernetes Overlay (Virtual, not VLAN-tagged)

| Range Name | CIDR | Scope | Purpose | Notes |
|---|---|---|---|---|
| Pod CIDR | 10.1.200.0/22 | Project 1 (virtual) | Kubernetes pod-to-pod networking (CNI overlay) | Requires `--cluster-cidr` override at k3s install; default is `10.42.0.0/16`. **Capacity ceiling:** at the default /24-per-node allocation, a /22 supports a maximum of 4 nodes - the current 3 plus exactly one more. Before adding a 5th node, either widen to /21 (would require redeploying the CNI) or shrink the per-node mask via `--kube-controller-manager-arg=node-cidr-mask-size=25`. |
| Service CIDR | 10.1.204.0/24 | Project 1 (virtual) | Kubernetes ClusterIP service addresses | Requires `--service-cidr` override at k3s install; default is `10.43.0.0/16`. |

## Design Notes

- **VLAN 1 avoided:** left unused rather than carrying shared mgmt traffic, since VLAN 1 is the
  default/native VLAN on most switches and is more exposed to VLAN-hopping attacks. Shared mgmt
  moved to VLAN 10.
- **Corosync on VLAN 10:** sharing the mgmt VLAN with Proxmox corosync is acceptable for this
  scale, but corosync is latency-sensitive - if you see cluster instability under load, consider
  breaking it out to its own dedicated low-latency link/VLAN.
- **Router-on-a-stick:** the switch is L2-only (VLAN trunk); the router holds the actual gateway
  IPs for VLAN 11 and VLAN 13 via 802.1Q sub-interfaces (rows above). Left out of
  `network_visualization.md`'s edge list to keep that diagram readable - this table is the source
  of truth for gateway ownership.
- **VLAN 12 is deliberately L2-only (no gateway):** all Longhorn replica/engine traffic is
  node-to-node within the VLAN (eth1 <-> eth1), so a gateway would route nothing legitimate.
  Removing the router sub-interface makes the storage VLAN unreachable from every other VLAN
  *by construction* - isolation no longer depends on router ACLs staying correct. The k8s VMs'
  eth1 interfaces are configured with an IP and netmask only: **no gateway, no default route**
  (a second default route would risk asymmetric routing). Trade-off: storage NICs can't be
  pinged from the mgmt VLAN; diagnose by SSHing into a k8s node and pinging across VLAN 12
  from there.
- **Jumbo frames on VLAN 12:** recommended MTU 9000 for Longhorn replica traffic - the isolated
  L2 segment is the safest possible place for jumbo frames (no path-MTU discovery issues, no
  mixed-MTU neighbors). MTU must match end-to-end: switch ports (or switch-wide), the Proxmox
  bridge/VLAN interface on each pve host, and eth1 inside each k8s VM. Leave every other VLAN
  at 1500.
- **Trusted Devices on VLAN 13, not VLAN 10:** personal daily-driver devices (laptops, phones)
  live on their own VLAN rather than the mgmt VLAN, so a compromised or merely-curious personal
  device has no path to Proxmox/PBS/switch mgmt interfaces. From VLAN 13 you can reach: published
  apps (MetalLB/ingress pool), the kube API (kubectl), internal DNS/NTP, and the internet -
  nothing else. Administrative work (Proxmox web UI, SSH, Technitium admin UI) is done from a
  machine on VLAN 10 (e.g. a jump host / dedicated admin workstation).
- **DNS/NTP placement and redundancy:** runs as two LXCs on VLAN 10 (shared infra), not inside
  the k3s cluster - DNS/NTP are foundational dependencies and shouldn't go down with the cluster,
  or with any single hypervisor. The two instances are deliberately split across different
  Proxmox hosts (pve1, pve2) so losing one host doesn't take down both:
  - DNS: `10.0.10.4` is primary (authoritative for `home.arpa`); `10.0.10.5` is a secondary zone
    pulling updates from the primary via zone transfer. Clients should be configured with both
    as resolvers (primary first).
  - NTP: both `10.0.10.4` and `10.0.10.5` run independent chrony instances syncing from the
    public NTP pool - no replication needed, clients just list both as time sources.
  - The Proxmox hosts and PBS are themselves clients: point `/etc/resolv.conf` and chrony on
    pve1/pve2/pve3/PBS at `10.0.10.4` and `10.0.10.5` (intra-VLAN 10 traffic; see the LXC-FW
    rules in `firewall_rules.yaml` for the host-firewall allows that make this work).

  Root domain is `home.arpa` (RFC 8375) for infra hostnames; a real owned domain should be used
  for anything published via ingress, since `home.arpa` can't get a publicly-trusted TLS cert.
  Non-`home.arpa` queries are forwarded upstream to a public resolver.
- **Backup strategy (PBS + Longhorn split):** PBS backs up VM/CT *system* disks. The k8s VMs'
  Longhorn data disks are **excluded** from PBS backup jobs - Longhorn keeps 3 replicas of every
  volume, so backing up all three VMs whole would store three crash-consistent copies of the
  same data. Instead, Longhorn's built-in backup feature targets an NFS export (or S3/MinIO)
  hosted on the PBS box, giving app-consistent, deduplicated volume backups. Net result: PBS
  holds OS disks + Longhorn's own volume backups, once each.
- **Off-site copy (3-2-1):** PBS alone is one copy in the same room on the same power as
  everything it protects. Complete the 3-2-1 rule by syncing the PBS datastore off-site - either
  a PBS remote (sync job to a second PBS at another location) or an encrypted `rclone` push of
  the datastore to cloud object storage. Fire/theft/ransomware all defeat a single local copy.
- **Firewall rules:** the full rule set required for this network to function - inter-VLAN
  router ACLs plus documented intra-VLAN traffic - lives in `firewall_rules.yaml` next to this
  file, not duplicated here.
