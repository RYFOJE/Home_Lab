# Non-secret configuration for the 40-kube-networking layer. Safe to commit.
# Secrets (cloudflare-dns-api-token, public-domain, acme-email) live in Azure
# Key Vault, read via data.azurerm_key_vault_secret in main.tf.

key_vault_name                = "rj-london"
key_vault_resource_group_name = "terraform"

# VLAN 12 storage island (allocations.md); MTU must match eth1 (30-talos) and
# the physical path.
storage_network_cidr = "10.1.12.0/24"
storage_network_mtu  = 9000

longhorn_v2_data_engine = false

# Chart pins -- never latest, bump on purpose (Renovate proposes bumps).
cilium_chart_version       = "1.19.6"  # renovate: helmRepo=https://helm.cilium.io chart=cilium
cert_manager_chart_version = "v1.21.0" # renovate: helmRepo=https://charts.jetstack.io chart=cert-manager
longhorn_chart_version     = "1.12.0"  # renovate: helmRepo=https://charts.longhorn.io chart=longhorn
traefik_chart_version      = "41.0.2"  # renovate: helmRepo=https://traefik.github.io/charts chart=traefik
