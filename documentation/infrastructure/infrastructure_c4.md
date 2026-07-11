```mermaid
C4Deployment
title Homelab Infrastructure - Deployment Diagram (Level 1: Physical/Network + Kubernetes Nodes)

Deployment_Node(home, "Portfolio Home Network", "Physical Location"){

    Deployment_Node(router, "Router", "Network Device"){
        Container(router_c, "Router")
    }

    Deployment_Node(switch, "Switch", "Network Device"){
        Container(switch_c, "Switch")
    }

    Deployment_Node(pve1, "Proxmox Node 1", "Physical Server"){
        Container(pve1_hv, "Proxmox VE", "Hypervisor", "Hosts VMs")
        Deployment_Node(k8s1, "k8s-node-1", "Debian 12 + k3s VM"){
            Container(k8s1_c, "k3s Node", "Control-plane + Worker", "Combined role: part of etcd quorum, also schedules workloads")
        }
    }

    Deployment_Node(pve2, "Proxmox Node 2", "Physical Server"){
        Container(pve2_hv, "Proxmox VE", "Hypervisor", "Hosts VMs")
        Deployment_Node(k8s2, "k8s-node-2", "Debian 12 + k3s VM"){
            Container(k8s2_c, "k3s Node", "Control-plane + Worker", "Combined role: part of etcd quorum, also schedules workloads")
        }
    }

    Deployment_Node(pve3, "Proxmox Node 3", "Physical Server"){
        Container(pve3_hv, "Proxmox VE", "Hypervisor", "Hosts VMs")
        Deployment_Node(k8s3, "k8s-node-3", "Debian 12 + k3s VM"){
            Container(k8s3_c, "k3s Node", "Control-plane + Worker", "Combined role: part of etcd quorum, also schedules workloads")
        }
    }

    Deployment_Node(pbs, "Proxmox Backup Server", "Physical Server"){
        Container(pbs_sw, "Proxmox Backup Server", "Backup Software", "Stores VM/CT backups")
    }
}

Rel(router_c, switch_c, "Uplink", "Ethernet")
Rel(switch_c, pve1_hv, "Connects", "Ethernet")
Rel(switch_c, pve2_hv, "Connects", "Ethernet")
Rel(switch_c, pve3_hv, "Connects", "Ethernet")
Rel(switch_c, pbs_sw, "Connects", "Ethernet")

Rel(k8s1_c, k8s2_c, "etcd/API quorum", "TCP")
Rel(k8s2_c, k8s3_c, "etcd/API quorum", "TCP")
Rel(k8s3_c, k8s1_c, "etcd/API quorum", "TCP")

UpdateRelStyle(router_c, switch_c, $offsetY="-10")
```