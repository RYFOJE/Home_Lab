# ArgoCD server install. The GitOps bootstrap floor (root Application, the
# external-secrets namespace and the ESO credential) lives in gitops.tf;
# everything under kubernetes/apps -- and every in-cluster secret via ESO -- is
# deployed by ArgoCD from git, not by Terraform.
#
# Values live in values/argo-cd.yaml, which CI renders against the pinned chart
# version. The chart has no values schema, so a key that moves between versions
# is dropped in silence rather than refused -- rendering it in CI is the only
# thing that catches that.

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    # Baseline PSA is fine; no opt-out needed. Declared explicitly because
    # kyverno-policies' require-namespace-psa-label denies any namespace
    # without an enforce label -- on CREATE and on UPDATE, so an unlabelled
    # namespace would be frozen against future Terraform edits.
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Eleven pods across controller/server/repo-server/redis-ha behind image
  # pulls; the provider's 300s default times out on a cold rebuild and leaves a
  # partial release behind.
  timeout = 900

  values = [
    file("${path.module}/values/argo-cd.yaml"),
    yamlencode({
      configs = {
        secret = {
          # Key Vault holds the bcrypt hash itself
          # (argocd-admin-password-bcrypt): hashing with bcrypt() here would
          # generate a new salt every plan and roll the release on every apply.
          # Note the plaintext-equivalent hash and every Key Vault data-source
          # value do land in Terraform state -- state is sensitive regardless.
          argocdServerAdminPassword = data.azurerm_key_vault_secret.argocd_admin_password_bcrypt.value
        }
      }
      server = {
        ingress = {
          # traefik-internal terminates TLS with its wildcard cert; the
          # configs.params server.insecure entry in values/argo-cd.yaml is what
          # keeps ArgoCD serving plain HTTP behind it.
          hostname = "argocd.${local.domain}"
        }
      }
    }),
  ]
}
