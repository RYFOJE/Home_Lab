```mermaid
flowchart TB

    subgraph PHYSICAL["Physical Infrastructure - VLAN 10 Mgmt (10.0.10.0/24)"]
        ROUTER["Router<br/>10.0.10.1 (VLAN 10)<br/>10.1.11.1 (VLAN 11 gw)<br/>10.0.13.1 (VLAN 13 gw)"]
        SWITCH["Switch - L2 trunk only<br/>10.0.10.2"]
        PVE1["Proxmox pve1<br/>10.0.10.11"]
        PVE2["Proxmox pve2<br/>10.0.10.12"]
        PVE3["Proxmox pve3<br/>10.0.10.13"]
        PBS["Backup Server<br/>10.0.10.3"]

        ROUTER --- SWITCH
        SWITCH --- PVE1
        SWITCH --- PVE2
        SWITCH --- PVE3
        SWITCH --- PBS
    end

    USERS["Trusted Devices - VLAN 13<br/>10.0.13.0/24<br/>DHCP 10.0.13.100-199"]
    USERS --- SWITCH

    subgraph SHARED["Shared Services - LXCs on VLAN 10 (bridged via their Proxmox host)"]
        DNSNTP1["core-infra-1<br/>DNS + NTP Primary<br/>10.0.10.4"]
        DNSNTP2["core-infra-2<br/>DNS + NTP Secondary<br/>10.0.10.5"]
    end

    PVE1 -->|hosts| DNSNTP1
    PVE2 -->|hosts| DNSNTP2

    subgraph K8S["Kubernetes Cluster (k3s) - VLAN 11 Workloads (10.1.11.0/24)"]
        N1["k8s-node-1 (VM)<br/>Control-plane + Worker<br/>eth0 10.1.11.11"]
        N2["k8s-node-2 (VM)<br/>Control-plane + Worker<br/>eth0 10.1.11.12"]
        N3["k8s-node-3 (VM)<br/>Control-plane + Worker<br/>eth0 10.1.11.13"]
        VIP["API VIP - kube-vip<br/>10.1.11.10"]
        LB["MetalLB Pool<br/>10.1.11.50-99"]
    end

    PVE1 -->|hosts| N1
    PVE2 -->|hosts| N2
    PVE3 -->|hosts| N3

    VIP -.floats across.- N1
    VIP -.floats across.- N2
    VIP -.floats across.- N3
    LB -.announced by.- K8S

    OVERLAY["Overlay networks (virtual, not VLAN-tagged)<br/>Pod CIDR 10.1.200.0/22<br/>Service CIDR 10.1.204.0/24"]
    K8S -.- OVERLAY

    subgraph STORAGE["VLAN 12 Storage - isolated L2 island, NO gateway (10.1.12.0/24)"]
        S1["k8s-node-1 eth1<br/>10.1.12.11"]
        S2["k8s-node-2 eth1<br/>10.1.12.12"]
        S3["k8s-node-3 eth1<br/>10.1.12.13"]
        S1 ---|Longhorn replica traffic| S2
        S2 ---|Longhorn replica traffic| S3
        S3 ---|Longhorn replica traffic| S1
    end

    N1 -.same VM.- S1
    N2 -.same VM.- S2
    N3 -.same VM.- S3
```

Notes:

- The DNS/NTP LXCs have no cable of their own - they reach the switch through their
  Proxmox host's bridge (shown as `hosts` edges, not switch links).
- VLAN 12 has **no router sub-interface**: Longhorn traffic never leaves the L2 segment, and
  nothing outside it can route in. Node eth1 interfaces carry an IP + netmask only (no
  gateway). Recommended MTU 9000 on this VLAN only - see `allocations.md` design notes.
- Router gateway ownership per VLAN is deliberately not drawn as edges here to keep the
  diagram readable; `allocations.md` is the source of truth.
- Full traffic policy (who may talk to whom) lives in `firewall_rules.yaml`.
