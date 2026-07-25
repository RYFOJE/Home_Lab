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

There are no Terraform tests or linters beyond `terraform fmt` / `terraform validate`. `python scripts/check_cluster_policy.py` (PyYAML + `helm`, no cluster or Azure auth needed) renders every GitOps app and every Terraform-pinned chart and checks the result against what `kyverno-policies` enforces at admission — the image registry allow-list, the explicit-tag and `:latest` rules, the namespace PSA-label requirement including its allowed values (both chart-rendered namespaces and the app registry's `createNamespace`/`namespaceLabels` pairing), and the CRD annotation-size cap against each app's `ServerSideApply` setting. `--dump <dir>` writes the rendered manifests back out, stamping each app's destination namespace the way ArgoCD does; CI (`.github/workflows/cluster-policy-check.yml`) then runs the *real* policy files over that directory with the Kyverno CLI (`kyverno apply … --audit-warn`, pinned to the chart's appVersion), because the script's image and PSA checks are a hand-written mirror that can drift and only the engine catches an unresolved variable or a broken autogen rewrite. Runs on any PR touching `kubernetes/apps/**`, the app registry, or a chart-version pin. Helm test hooks are skipped everywhere — ArgoCD never applies one, and kyverno's ship on `:latest`.

Azure authentication is a prerequisite for everything: the state backend (storage account `rjterraform`, container `london`) and the Key Vault secret lookups both use Azure AD auth.

## Architecture

Layered Terraform under `terraform/`, applied in numeric order. Each layer has its own state file (`<layer>.tfstate` in the same backend), and downstream layers consume upstream outputs via `terraform_remote_state` — no local files pass between layers (kubeconfig included).

| Layer | Provider(s) | Provisions | Reads state from |
|---|---|---|---|
| `10-network` | ubiquiti-community/unifi | VLANs, WLANs, firewall rules (modules: `vlans`, `wlans`, `firewall`) | — |
| `20-proxmox` | bpg/proxmox, siderolabs/talos | Talos Image Factory schematic (Longhorn extensions baked in), k8s node VMs, core-infra DNS/NTP LXCs, PVE storage + firewall | — |
| `30-talos` | siderolabs/talos | Machine config (static IPs, VIP, Longhorn prereqs, CNI `none` + kube-proxy disabled — Cilium comes from 40-kube-networking), bootstrap, kubeconfig output | 20-proxmox |
| `40-kube-networking` | kubernetes, helm, alekc/kubectl, azurerm | Cilium (CNI, NetworkPolicy, kube-proxy replacement, LB IPAM + L2 announcements), Multus + whereabouts (vendored manifests in `manifests/`, no helm repo exists upstream), Longhorn, cert-manager (Cloudflare DNS-01 wildcard), Traefik ×2 (external 10.1.11.50 / internal 10.1.11.51) | 30-talos |
| `50-cloudflare` | cloudflare/cloudflare ~> 5, random, azurerm | Cloudflare Tunnel (remote-managed config), apex + wildcard CNAMEs → `<tunnel-id>.cfargotunnel.com` (tunnel mode only), tunnel token written to Key Vault as `cloudflared--tunnel-token` (the connector workload itself is the GitOps app `kubernetes/apps/edge/cloudflared`) | 10-network, 40-kube-networking |
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

In-cluster apps are deployed by ArgoCD from this repo, not by Terraform (`documentation/programming/gitops_apps.md`). `kubernetes/bootstrap/` is the root app-of-apps chart: its `values.yaml` is the app registry, and a Terraform-created root Application (60-argo-cd `gitops.tf`) points ArgoCD at it, injecting the public domain, Azure tenant, Key Vault URL, and `edge_mode` as Helm parameters so none appear in git. Each app is one directory under `kubernetes/apps/<group>/<name>/` (grouped by function — `security`, `monitoring`, `edge`) — an umbrella Helm chart pinning the upstream chart as a dependency plus a `values.yaml` (and optional `templates/`); apps without an upstream chart (cloudflared) are plain templates. Adding an app = new directory under the right group + one registry entry (`name` and `group` both set — the registry's `path` is `kubernetes/apps/{{ .group }}/{{ .name }}`), subject to the cluster-wide Kyverno rules below. A registry entry can be gated on the edge mode (`onlyEdgeMode: tunnel` — cloudflared only renders, and is pruned otherwise). ArgoCD creates namespaces (one owning app each, PSA labels via `managedNamespaceMetadata`); Terraform owns only `external-secrets`, whose PSA label is set on the `kubernetes_namespace` resource rather than in the registry (`kubernetes_namespace` replaces the whole labels map, so an ArgoCD-managed label would flap on every apply). In-cluster secrets come from Azure Key Vault via External Secrets Operator through the single `azure-kv` ClusterSecretStore, with Key Vault keys named `<namespace>--<name>` and a Kyverno policy blocking any namespace from reading another's keys or introducing a second store (`kubernetes/apps/security/cluster-secrets`). Terraform's only in-cluster secret is the ESO bootstrap credential. A second policy app, `kubernetes/apps/security/kyverno-policies`, enforces general hardening cluster-wide: every namespace must carry a `pod-security.kubernetes.io/enforce` label (on update as well as create, so Terraform-created namespaces set one too) whose value is `baseline` or `restricted` outside `longhorn-system` and `monitoring-system` — requiring only presence would enforce that the knob is set, not what it is set to, letting any app opt out of PSA in one line; container images must resolve to `docker.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`, `reg.kyverno.io` or `ecr-public.aws.com` and carry an explicit non-`latest` tag; no new `cluster-admin` bindings (Longhorn's `longhorn-support-bundle` is excluded by name — the chart creates it unconditionally, and a `ClusterRoleBinding` is cluster-scoped so a namespace exclusion would not match). Those three pin `spec.webhookConfiguration.failurePolicy: Fail` (policy-level, not per-rule) — fail-closed, so they reject rather than flag: adding an app or taking a major chart bump means re-rendering it and checking its image registries against that list. A fourth policy, `workload-best-practices`, is report-only (probes, CPU/memory requests, memory limit) and pins `Ignore` instead — `failurePolicy` governs webhook *unreachability*, unrelated to `failureAction`, so putting `Audit` rules behind a fail-closed webhook would widen an outage's blast radius to buy nothing. Rules are JMESPath, never CEL: the chart enables `generateValidatingAdmissionPolicy`, and a single-rule CEL `ClusterPolicy` matching Pods gets promoted to a native `ValidatingAdmissionPolicy`, which sends `Audit` results to the API-server audit log instead of the `PolicyReport`s they exist to populate. An app whose rendered CRDs exceed the 262144-byte `last-applied-configuration` annotation cap needs `ServerSideApply=true` in its registry entry (`external-secrets`, `kyverno`, `kube-prometheus-stack` today) — check with `helm template <app> --include-crds` on a chart bump. Sync waves are load-bearing, not cosmetic — a wave that cannot apply blocks every later one, so nothing before wave `1` may render a `monitoring.coreos.com` kind (those CRDs come with kube-prometheus-stack at wave `0`); Kyverno's ServiceMonitor and alerts are a separate `kyverno-monitoring` app for exactly that reason. The observability stack (kube-prometheus-stack, Loki, Tempo, Alloy — `documentation/infrastructure/observability.md`) is deployed this way.

## Documentation

`documentation/` is the design source of truth; Terraform comments cite it. Keep both in sync when changing network or cluster config:

- `networking/allocations.md` — authoritative IP/VLAN plan and design notes. Addressing convention: 2nd octet = scope (0 = shared, 1 = Project 1, ...), 3rd octet = VLAN ID.
- `networking/firewall_rules.yaml` — the exact rule set (router + Proxmox host layers). Rule IDs renumber on change; one field per line to keep diffs isolated.
- `networking/wifi_and_isolation.md` — SSID layout, trust zones, Traefik public edge.
- `infrastructure/infrastructure_c4.md` — mermaid C4 deployment diagram.
- `programming/publishing_apps.md` — how an app selects `traefik-external` vs `traefik-internal` (ingressClass), TLS, and DNS.
- `programming/gitops_apps.md` — the cluster-wide GitOps convention: umbrella charts, app registry, domain injection, sync policy.
- `infrastructure/observability.md` — the monitoring/logging/tracing stack: components, retention, OTLP endpoints, Talos scrape disables, alert routing.
- `infrastructure/disaster_recovery.md` — recovery runbook: triage diagram, rebuild order with per-layer secrets and verify checks, state rollback, break-glass credentials.

Load-bearing design decisions to preserve: VLAN 12 (Longhorn storage) is an L2-only island — no gateway, no router sub-interface, MTU 9000 end-to-end; the Kubernetes API VIP (10.1.11.10) is Talos-native, not kube-vip; all three nodes are combined control-plane + worker; pod/service CIDRs are overridden to fit the addressing plan (pod /22 caps the cluster at 4 nodes); Cilium is the network stack (CNI, kube-proxy replacement, NetworkPolicy enforcement, LB IPAM with L2 announcements on eth0 only — never the storage island); the public edge is two Traefik instances split by exposure — external 10.1.11.50, internal 10.1.11.51 (never exposed) — with a cert-manager Cloudflare DNS-01 wildcard cert; public traffic reaches the external instance via a Cloudflare Tunnel (50-cloudflare: cloudflared dials out udp 7844 QUIC, FW-015) so no WAN port-forward exists in the end state — a single `edge_mode` ("tunnel"|"dnat"), owned by 10-network's tfvars and read via remote state by 50-cloudflare and 60-argo-cd, gates the DNAT fallback (FW-017), the public DNS records, and the cloudflared GitOps app (flip it in 10-network, then apply 10-network, 50-cloudflare, 60-argo-cd); and the public domain itself is a Key Vault secret, never committed.

Documentation style: lean and declarative. State decisions and facts; do not give advice or present options. "Temporary" fixes are not documented — only good ones.
