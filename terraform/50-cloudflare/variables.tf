# All values live in terraform.tfvars -- no defaults here, so a missing value
# fails the plan loudly instead of silently applying a stale default (same
# convention as 10-network / 20-proxmox). edge_mode is the exception: it is
# owned by 10-network and read via remote state (main.tf), not set here.

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

variable "cloudflared_image" {
  description = "cloudflared container image, pinned by calendar tag (never latest -- autoupdate is disabled in the pod args). Bump deliberately."
  type        = string
}

variable "cloudflared_replicas" {
  description = "cloudflared replica count. Required anti-affinity spreads one per node, so this must not exceed the node count."
  type        = number
}

variable "traefik_external_namespace" {
  description = "Namespace of the external Traefik instance in 40-Kube-Networking (the tunnel origin). The Service shares this name -- the origin FQDN is built from it in tunnel.tf. Cross-layer coupling: must match 40-Kube-Networking' traefik_external instance_name (\"traefik-<name>\")."
  type        = string
}
