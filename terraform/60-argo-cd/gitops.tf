# GitOps bootstrap. ArgoCD deploys everything under kubernetes/apps from git
# (documentation/programming/gitops_apps.md); in-cluster secrets come from
# Azure Key Vault through External Secrets Operator. Terraform's role is the
# irreducible floor that cannot itself come from git:
#   1. the external-secrets namespace,
#   2. the Service Principal credential ESO authenticates to Key Vault with
#      (a chicken-and-egg: ESO cannot read its own credential from the vault),
#   3. the root Application pointer, injecting the domain and tenant so neither
#      lands in git.
# Namespaces, the ClusterSecretStore and every app secret are git/ESO-managed.

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

# Consumed by the azure-kv ClusterSecretStore
# (kubernetes/apps/cluster-secrets). The only namespace this credential exists
# in -- a namespaced SecretStore elsewhere would have no credential to use, and
# Kyverno forbids a second ClusterSecretStore, so no namespace can reach Key
# Vault by any other path.
resource "kubernetes_secret" "azure_kv_creds" {
  metadata {
    name      = "azure-kv-creds"
    namespace = kubernetes_namespace.external_secrets.metadata[0].name
  }

  data = {
    "client-id"     = data.azurerm_key_vault_secret.azure_kv_sp_client_id.value
    "client-secret" = data.azurerm_key_vault_secret.azure_kv_sp_client_secret.value
  }
}

# Root app-of-apps: points ArgoCD at kubernetes/bootstrap, which renders one
# Application per registry entry. kubectl_manifest (not kubernetes_manifest)
# because the Application CRD only exists after helm_release.argocd --
# kubernetes_manifest needs the CRD at plan time and breaks fresh rebuilds
# (same reasoning as 40-kube-networking).
resource "kubectl_manifest" "root_app" {
  depends_on = [helm_release.argocd]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_revision
        path           = "kubernetes/bootstrap"
        helm = {
          parameters = [
            # The public domain is a Key Vault secret (PII rule); the tenant id
            # is likewise injected so neither appears in git.
            { name = "domain", value = local.domain },
            { name = "tenantId", value = data.azurerm_client_config.current.tenant_id },
            { name = "repoURL", value = var.gitops_repo_url },
            { name = "revision", value = var.gitops_revision },
            # Vault URL derived from the same Key Vault Terraform reads --
            # single source of truth instead of a copy in git.
            { name = "vaultUrl", value = trimsuffix(data.azurerm_key_vault.this.vault_uri, "/") },
            # From 10-network remote state: gates apps whose registry entry
            # sets onlyEdgeMode (cloudflared renders only in tunnel mode).
            # Flipping edge_mode: apply 10-network, 50-cloudflare, then here.
            { name = "edgeMode", value = data.terraform_remote_state.network.outputs.edge_mode },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })
}
