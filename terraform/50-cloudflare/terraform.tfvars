# Non-secret configuration for the 50-cloudflare layer. Safe to commit.
# Secrets (cloudflare-dns-api-token, cloudflare-account-id, public-domain)
# live in Azure Key Vault, read via data.azurerm_key_vault_secret in main.tf.
# edge_mode is NOT set here -- it is owned by 10-network and read from its
# remote state (that terraform.tfvars is the single source of truth).

key_vault_name                = "rj-london"
key_vault_resource_group_name = "terraform"

tunnel_name          = "london-homelab-edge"
cloudflared_image    = "cloudflare/cloudflared:2026.7.2"
cloudflared_replicas = 3

# Origin: the external Traefik instance from 40-kube-networking (must match its
# traefik_external instance_name -> namespace "traefik-<name>").
traefik_external_namespace = "traefik-external"
