# All values live in terraform.tfvars -- no defaults here, so a missing value
# fails the plan loudly instead of silently applying a stale default (same
# convention as 10-network / 20-proxmox).

variable "key_vault_name" {
  description = "Azure Key Vault holding the edge secrets (public-domain, acme-email). The Cloudflare token is reached through ESO, not by this layer."
  type        = string
}

variable "key_vault_resource_group_name" {
  description = "Resource group of the Key Vault."
  type        = string
}

variable "storage_network_cidr" {
  description = "VLAN 12 Longhorn storage network (L2-only, no gateway)"
  type        = string
}

variable "storage_network_mtu" {
  description = "MTU for the macvlan storage-network attachment. Must match eth1 (30-talos) and the physical path."
  type        = number
}

variable "cilium_chart_version" {
  description = "cilium helm chart version, pinned deliberately (never latest -- bump on purpose)."
  type        = string
}

variable "cert_manager_chart_version" {
  description = "cert-manager helm chart version, pinned deliberately."
  type        = string
}

variable "longhorn_chart_version" {
  description = "longhorn helm chart version, pinned deliberately."
  type        = string
}

variable "traefik_chart_version" {
  description = "traefik helm chart version, pinned deliberately. Shared by both instances."
  type        = string
}

variable "traefik_crds_chart_version" {
  description = "traefik-crds helm chart version. Separate from the traefik chart because helm never upgrades a chart's own crds/ directory; republished only when the CRDs change, so its number lags traefik's."
  type        = string
}
