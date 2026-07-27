# cert-manager issues the wildcard certificate for the public domain via ACME
# DNS-01 against Cloudflare (the domain's DNS host). DNS-01 keeps ACME off the
# WAN path entirely -- port 80 is never needed for issuance -- and permits a
# wildcard, so internal-only hostnames get valid TLS without appearing in
# public DNS or certificate-transparency logs individually.
#
# This layer no longer holds the Cloudflare token. The Secret the solver reads
# is synced from Key Vault by External Secrets Operator
# (kubernetes/apps/security/cluster-secrets, key
# cert-manager--cloudflare-dns-api-token), which is why the token no longer
# appears in this layer's state and why rotating it is a vault edit rather than
# an apply.
#
# The ordering cost is real and deliberate: ESO arrives with ArgoCD at layer
# 60, so on a from-scratch build the ClusterIssuer below cannot solve a
# challenge until layer 60 has run. The wildcard Certificates stay Pending and
# Traefik serves its built-in self-signed cert until then, after which issuance
# happens unattended. documentation/infrastructure/disaster_recovery.md moves
# the "wildcard cert issued" check to step 9 for this reason.

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
    # Baseline PSA is fine; no opt-out needed. Declared explicitly because
    # kyverno-policies' require-namespace-psa-label denies any namespace
    # without an enforce label -- on CREATE and on UPDATE, so an unlabelled
    # namespace would be frozen against future Terraform edits.
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

resource "helm_release" "cert_manager" {
  # values/cert-manager.yaml names platform-critical; a pod naming a class that
  # does not exist is rejected at admission (scheduling.tf).
  depends_on = [data.talos_cluster_health.post_cilium, local.priority_classes]

  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.cert_manager_chart_version
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  # CRDs plus three deployments behind image pulls; 300s is tight on a cold
  # rebuild and a timeout leaves a partial release.
  timeout = 600

  # Values live in values/cert-manager.yaml -- read here and by
  # scripts/check_cluster_policy.py, so CI renders what Terraform applies.
  values = [file("${path.module}/values/cert-manager.yaml")]
}

resource "kubectl_manifest" "letsencrypt_issuer" {
  depends_on = [helm_release.cert_manager]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "letsencrypt" }
    spec = {
      acme = {
        server              = "https://acme-v02.api.letsencrypt.org/directory"
        email               = data.azurerm_key_vault_secret.acme_email.value
        privateKeySecretRef = { name = "letsencrypt-account-key" }
        solvers = [{
          dns01 = {
            cloudflare = {
              # Synced by ESO from Key Vault. The Secret name and key are fixed
              # in kubernetes/apps/security/cluster-secrets/templates/
              # cert-manager-external-secret.yaml.
              apiTokenSecretRef = {
                name = "cloudflare-api-token"
                key  = "api-token"
              }
            }
          }
        }]
      }
    }
  })
}
