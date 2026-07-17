# ArgoCD server only -- no Application/AppProject resources here. GitOps
# self-management of this repo is a deliberate follow-on step, not part of
# the install.

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
        # bcrypt so the plaintext Key Vault value never lands in the release
        # values/state beyond a one-way hash.
        argocdServerAdminPassword = bcrypt(data.azurerm_key_vault_secret.argocd_admin_password.value)
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
    }
    # HA: sharding across 2 controller pods (not active/active -- each shard
    # owns a subset of managed clusters), 2 repo-server/applicationset pods,
    # and redis-ha (Sentinel-backed, 3 pods) replacing the single redis pod.
    # 3 nodes total (30-talos), hardAntiAffinity spreads redis-ha 1/node.
    controller = {
      replicas = 2
      pdb      = { enabled = true, maxUnavailable = 1 }
    }
    repoServer = {
      replicas = 2
      pdb      = { enabled = true, maxUnavailable = 1 }
    }
    applicationSet = {
      replicas = 2
    }
    redis = {
      enabled = false
    }
    "redis-ha" = {
      enabled          = true
      hardAntiAffinity = true
      haproxy          = { enabled = true }
    }
  })]
}
