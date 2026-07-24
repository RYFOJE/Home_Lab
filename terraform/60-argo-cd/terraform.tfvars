# Non-secret configuration for the 60-argo-cd layer. Safe to commit.
# Secrets read by main.tf (argocd-admin-password-bcrypt, azure-kv-sp-*,
# public-domain) live in Azure Key Vault via data.azurerm_key_vault_secret.
# In-cluster app secrets (grafana, alertmanager, ...) go through ESO instead
# (documentation/secrets.md).

key_vault_name                = "rj-london"
key_vault_resource_group_name = "terraform"

argocd_chart_version = "7.8.2" # renovate: helmRepo=https://argoproj.github.io/argo-helm chart=argo-cd

gitops_repo_url = "https://github.com/RYFOJE/Home_Lab.git"
gitops_revision = "main"
