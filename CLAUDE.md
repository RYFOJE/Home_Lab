# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

Homelab infrastructure-as-code plus its documentation. Terraform provisions the UniFi network, Proxmox VMs/LXCs, a Talos Kubernetes cluster, and in-cluster apps. The documentation is self-documentation for disaster recovery.

Never commit personally identifying information: WAN IPs, public domain names, passwords, keys, or tokens (README.md). All secrets live in Azure Key Vault and are read at plan time via `azurerm_key_vault_secret` data sources — follow that pattern for any new secret, and record it in `documentation/secrets.md` (the full secret inventory: name, consumer, purpose). The one secret Terraform *writes* to the vault is the tunnel token (`cloudflared--tunnel-token`, 50-cloudflare) — it flows to the cluster through ESO like any app secret.

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
| `30-talos` | siderolabs/talos | Machine config (static IPs, VIP, Longhorn prereqs, CNI `none` + kube-proxy disabled — Cilium comes from 40-kube-networking), bootstrap, kubeconfig output | 20-proxmox |
| `40-kube-networking` | kubernetes, helm, alekc/kubectl, azurerm | Cilium (CNI, NetworkPolicy, kube-proxy replacement, LB IPAM + L2 announcements), Multus + whereabouts (vendored manifests in `manifests/`, no helm repo exists upstream), Longhorn, cert-manager (Cloudflare DNS-01 wildcard), Traefik ×2 (external 10.1.11.50 / internal 10.1.11.51) | 30-talos |
| `50-cloudflare` | cloudflare/cloudflare ~> 5, random, azurerm | Cloudflare Tunnel (remote-managed config), apex + wildcard CNAMEs → `<tunnel-id>.cfargotunnel.com` (tunnel mode only), tunnel token written to Key Vault as `cloudflared--tunnel-token` (the connector workload itself is the GitOps app `kubernetes/apps/cloudflared`) | 10-network, 40-kube-networking |
| `60-argo-cd` | kubernetes, helm, alekc/kubectl, azurerm | ArgoCD (GitOps controller + UI) via the argo-helm chart, published behind `traefik-internal` (LAN-only, admin tool); GitOps bootstrap floor (`gitops.tf`): root app-of-apps Application (injects domain, tenant, vault URL and `edge_mode`), the `external-secrets` namespace, and the `azure-kv-creds` Service Principal secret for External Secrets Operator | 30-talos, 10-network |

Ordering caveats:
- core-infra LXCs (20-proxmox) provide DNS/NTP for the whole network; their software (Technitium + chrony) is configured manually/Ansible **before** applying 30-talos — Talos nodes resolve and sync time against them from first boot, and the firewall blocks public resolvers.
- `20-proxmox/storage.tf` imports the existing `local` datastore; its `content` list replaces live config — reconcile with `pvesm status` before applying changes there.
- Talos VMs run without qemu-guest-agent (Talos doesn't ship it); enabling it hangs applies.
- 40-kube-networking installs the CNI: on a fresh rebuild, nodes stay NotReady after 30-talos until 40-kube-networking applies Cilium — apply the two layers back-to-back.
- 50-cloudflare requires 40-kube-networking applied first (traefik-external is the tunnel origin, read via remote state) and, in Key Vault, the broadened `cloudflare-dns-api-token` scopes plus the `cloudflare-account-id` secret (see `documentation/secrets.md`). Its plan needs the Cloudflare API and Key Vault reachable — not the cluster.
- 60-argo-cd requires 40-kube-networking applied first (traefik-internal + the cert-manager wildcard cert must exist for the Ingress to get TLS), and the `argocd-admin-password-bcrypt` secret set in Key Vault before apply (a pre-computed bcrypt hash — `argocd account bcrypt --password <pw>` — because Terraform's `bcrypt()` re-salts every plan).
- Flipping `edge_mode` is a three-layer apply: 10-network (forwards/rules), 50-cloudflare (public DNS records), 60-argo-cd (re-renders the root Application's `edgeMode` parameter, which gates the cloudflared app — ArgoCD prunes or creates it).

`terraform.tfvars` files are committed on purpose — they hold non-secret configuration only.

## GitOps (`kubernetes/`)

In-cluster apps are deployed by ArgoCD from this repo, not by Terraform (`documentation/programming/gitops_apps.md`). `kubernetes/bootstrap/` is the root app-of-apps chart: its `values.yaml` is the app registry, and a Terraform-created root Application (60-argo-cd `gitops.tf`) points ArgoCD at it, injecting the public domain, Azure tenant, Key Vault URL, and `edge_mode` as Helm parameters so none appear in git. Each app is one directory under `kubernetes/apps/<name>/` — an umbrella Helm chart pinning the upstream chart as a dependency plus a `values.yaml` (and optional `templates/`); apps without an upstream chart (cloudflared) are plain templates. Adding an app = new directory + one registry entry. A registry entry can be gated on the edge mode (`onlyEdgeMode: tunnel` — cloudflared only renders, and is pruned otherwise). ArgoCD creates namespaces (one owning app each, PSA labels via `managedNamespaceMetadata`); Terraform owns only `external-secrets`. In-cluster secrets come from Azure Key Vault via External Secrets Operator through the single `azure-kv` ClusterSecretStore, with Key Vault keys named `<namespace>--<name>` and a Kyverno policy blocking any namespace from reading another's keys or introducing a second store (`kubernetes/apps/cluster-secrets`). Terraform's only in-cluster secret is the ESO bootstrap credential. The observability stack (kube-prometheus-stack, Loki, Tempo, Alloy — `documentation/infrastructure/observability.md`) is deployed this way.

## Documentation

`documentation/` is the design source of truth; Terraform comments cite it. Keep both in sync when changing network or cluster config:

- `networking/allocations.md` — authoritative IP/VLAN plan and design notes. Addressing convention: 2nd octet = scope (0 = shared, 1 = Project 1, ...), 3rd octet = VLAN ID.
- `networking/firewall_rules.yaml` — the exact rule set (router + Proxmox host layers). Rule IDs renumber on change; one field per line to keep diffs isolated.
- `networking/wifi_and_isolation.md` — SSID layout, trust zones, Traefik public edge.
- `infrastructure/infrastructure_c4.md` — mermaid C4 deployment diagram.
- `programming/publishing_apps.md` — how an app selects `traefik-external` vs `traefik-internal` (ingressClass), TLS, and DNS.
- `programming/gitops_apps.md` — the cluster-wide GitOps convention: umbrella charts, app registry, domain injection, sync policy.
- `infrastructure/observability.md` — the monitoring/logging/tracing stack: components, retention, OTLP endpoints, Talos scrape disables, alert routing.

Load-bearing design decisions to preserve: VLAN 12 (Longhorn storage) is an L2-only island — no gateway, no router sub-interface, MTU 9000 end-to-end; the Kubernetes API VIP (10.1.11.10) is Talos-native, not kube-vip; all three nodes are combined control-plane + worker; pod/service CIDRs are overridden to fit the addressing plan (pod /22 caps the cluster at 4 nodes); Cilium is the network stack (CNI, kube-proxy replacement, NetworkPolicy enforcement, LB IPAM with L2 announcements on eth0 only — never the storage island); the public edge is two Traefik instances split by exposure — external 10.1.11.50, internal 10.1.11.51 (never exposed) — with a cert-manager Cloudflare DNS-01 wildcard cert; public traffic reaches the external instance via a Cloudflare Tunnel (50-cloudflare: cloudflared dials out udp 7844 QUIC, FW-015) so no WAN port-forward exists in the end state — a single `edge_mode` ("tunnel"|"dnat"), owned by 10-network's tfvars and read via remote state by 50-cloudflare and 60-argo-cd, gates the DNAT fallback (FW-017), the public DNS records, and the cloudflared GitOps app (flip it in 10-network, then apply 10-network, 50-cloudflare, 60-argo-cd); and the public domain itself is a Key Vault secret, never committed.

Documentation style: lean and declarative. State decisions and facts; do not give advice or present options. "Temporary" fixes are not documented — only good ones.
