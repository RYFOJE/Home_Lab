# All values live in terraform.tfvars -- no defaults here, so a missing value
# fails the plan loudly instead of silently applying a stale default (same
# convention as 10-network / 20-proxmox / 50-cloudflare).

variable "key_vault_name" {
  description = "Name of the Azure Key Vault holding this layer's secrets (argocd-admin-password, public-domain)."
  type        = string
}

variable "key_vault_resource_group_name" {
  description = "Resource group containing key_vault_name."
  type        = string
}

variable "argocd_chart_version" {
  description = "argo-cd helm chart version, pinned deliberately (never latest -- bump on purpose)."
  type        = string
}

variable "gitops_repo_url" {
  description = "Git repository ArgoCD syncs kubernetes/ from (public repo -- no credential)."
  type        = string
}

variable "gitops_revision" {
  description = "Branch or tag ArgoCD tracks for the root app-of-apps and all child apps."
  type        = string
}
