# ArgoCD server install. The GitOps bootstrap floor (root Application, the
# external-secrets namespace and the ESO credential) lives in gitops.tf;
# everything under kubernetes/apps -- and every in-cluster secret via ESO --
# is deployed by ArgoCD from git, not by Terraform.

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd" # baseline PSA is fine; no opt-out labels needed
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [yamlencode({
    configs = {
      secret = {
        # Key Vault holds the bcrypt hash itself (argocd-admin-password-bcrypt):
        # hashing with bcrypt() here would generate a new salt every plan and
        # roll the release on every apply. Note the plaintext-equivalent hash
        # and every Key Vault data-source value do land in Terraform state --
        # state is sensitive regardless.
        argocdServerAdminPassword = data.azurerm_key_vault_secret.argocd_admin_password_bcrypt.value
      }
    }
    server = {
      # traefik-internal terminates TLS with its wildcard cert; ArgoCD serves
      # plain HTTP behind it to avoid a double-TLS/redirect loop.
      insecure = true
      ingress = {
        enabled          = true
        ingressClassName = "traefik-internal"
        hostname         = "argocd.${local.domain}"
        tls              = true
      }
      replicas = 2
      pdb      = { enabled = true, maxUnavailable = 1 }
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
    }
    # HA: sharding across 2 controller pods (not active/active -- each shard
    # owns a subset of managed clusters), 2 repo-server pods, and redis-ha
    # (Sentinel-backed, 3 pods) replacing the single redis pod. 3 nodes total
    # (30-talos), hardAntiAffinity spreads redis-ha 1/node.
    controller = {
      replicas = 2
      pdb      = { enabled = true, maxUnavailable = 1 }
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
    }
    repoServer = {
      replicas = 2
      pdb      = { enabled = true, maxUnavailable = 1 }
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }
    redis = {
      enabled = false
    }
    "redis-ha" = {
      enabled          = true
      hardAntiAffinity = true
      haproxy          = { enabled = true }
      redis = {
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { memory = "256Mi" }
        }
      }
    }
  })]
}
