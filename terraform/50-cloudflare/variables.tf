# All values live in terraform.tfvars -- no defaults here, so a missing value
# fails the plan loudly instead of silently applying a stale default (same
# convention as 10-network / 20-proxmox). edge_mode is the exception: it is
# owned by 10-network and read via remote state (main.tf), not set here; the
# external Traefik namespace likewise comes from 40-kube-networking's state.

variable "key_vault_name" {
  description = "Name of the Azure Key Vault holding this layer's secrets (cloudflare-dns-api-token, cloudflare-account-id, public-domain)."
  type        = string
}

variable "key_vault_resource_group_name" {
  description = "Resource group containing key_vault_name."
  type        = string
}

variable "tunnel_name" {
  description = "Cloudflare Tunnel display name (shown in the Zero Trust dashboard)."
  type        = string
}
