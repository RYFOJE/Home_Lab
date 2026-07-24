# Non-secret configuration for the 50-cloudflare layer. Safe to commit.
# Secrets (cloudflare-dns-api-token, cloudflare-account-id, public-domain)
# live in Azure Key Vault, read via data.azurerm_key_vault_secret in main.tf.
# edge_mode is NOT set here -- it is owned by 10-network and read from its
# remote state (that terraform.tfvars is the single source of truth). The
# cloudflared workload itself is a GitOps app (kubernetes/apps/cloudflared).

key_vault_name                = "rj-london"
key_vault_resource_group_name = "terraform"

tunnel_name = "london-homelab-edge"
