# Non-secret configuration for the 60-argo-cd layer. Safe to commit.
# Secrets (argocd-admin-password, public-domain) live in Azure Key Vault,
# read via data.azurerm_key_vault_secret in main.tf.

key_vault_name                = "rj-london"
key_vault_resource_group_name = "terraform"

argocd_chart_version = "7.8.2"
