# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

Homelab infrastructure-as-code plus its documentation. Terraform provisions the UniFi network, Proxmox VMs/LXCs, a Talos Kubernetes cluster, and in-cluster apps. The documentation is self-documentation for disaster recovery.

Never commit personally identifying information: WAN IPs, public domain names, passwords, keys, or tokens (README.md). All secrets live in Azure Key Vault and are read at plan time via `azurerm_key_vault_secret` data sources — follow that pattern for any new secret.

## Commands

All Terraform runs per layer directory (`cd terraform/<layer>`):

```
terraform init            # azurerm backend; requires prior `az login` (use_azuread_auth)
terraform plan
terraform apply
terraform fmt -recursive  # formatting
terraform validate
```

There are no tests or linters beyond `terraform fmt` / `terraform validate`.

Azure authentication is a prerequisite for everything: the state backend (storage account `rjterraform`, container `london`) and the Key Vault secret lookups both use Azure AD auth.

## Architecture

Layered Terraform under `terraform/`, applied in numeric order. Each layer has its own state file (`<layer>.tfstate` in the same backend), and downstream layers consume upstream outputs via `terraform_remote_state` — no local files pass between layers (kubeconfig included).

| Layer | Provider(s) | Provisions | Reads state from |
|---|---|---|---|
| `10-network` | ubiquiti-community/unifi | VLANs, WLANs, firewall rules (modules: `vlans`, `wlans`, `firewall`) | — |
| `20-proxmox` | bpg/proxmox, siderolabs/talos | Talos Image Factory schematic (Longhorn extensions baked in), k8s node VMs, core-infra DNS/NTP LXCs, PVE storage + firewall | — |
| `30-talos` | siderolabs/talos | Machine config (static IPs, VIP, Longhorn prereqs), bootstrap, kubeconfig output | 20-proxmox |
| `40-apps` | kubernetes, helm, alekc/kubectl | Multus + whereabouts (vendored manifests in `manifests/`, no helm repo exists upstream), Longhorn | 30-talos |

Ordering caveats:
- core-infra LXCs (20-proxmox) provide DNS/NTP for the whole network; their software (Technitium + chrony) is configured manually/Ansible **before** applying 30-talos — Talos nodes resolve and sync time against them from first boot, and the firewall blocks public resolvers.
- `20-proxmox/storage.tf` imports the existing `local` datastore; its `content` list replaces live config — reconcile with `pvesm status` before applying changes there.
- Talos VMs run without qemu-guest-agent (Talos doesn't ship it); enabling it hangs applies.

`terraform.tfvars` files are committed on purpose — they hold non-secret configuration only.

## Documentation

`documentation/` is the design source of truth; Terraform comments cite it. Keep both in sync when changing network or cluster config:

- `networking/allocations.md` — authoritative IP/VLAN plan and design notes. Addressing convention: 2nd octet = scope (0 = shared, 1 = Project 1, ...), 3rd octet = VLAN ID.
- `networking/firewall_rules.yaml` — the exact rule set (router + Proxmox host layers). Rule IDs renumber on change; one field per line to keep diffs isolated.
- `networking/wifi_and_isolation.md` — SSID layout, trust zones, YARP public edge.
- `infrastructure/infrastructure_c4.md` — mermaid C4 deployment diagram.

Load-bearing design decisions to preserve: VLAN 12 (Longhorn storage) is an L2-only island — no gateway, no router sub-interface, MTU 9000 end-to-end; the Kubernetes API VIP (10.1.11.10) is Talos-native, not kube-vip; all three nodes are combined control-plane + worker; pod/service CIDRs are overridden to fit the addressing plan (pod /22 caps the cluster at 4 nodes).

Documentation style: lean and declarative. State decisions and facts; do not give advice or present options. "Temporary" fixes are not documented — only good ones.
