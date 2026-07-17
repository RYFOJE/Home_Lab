# cert-manager issues the wildcard certificate for the public domain via ACME
# DNS-01 against Cloudflare (the domain's DNS host). DNS-01 keeps ACME off the
# WAN path entirely -- port 80 is never needed for issuance -- and permits a
# wildcard, so internal-only hostnames get valid TLS without appearing in
# public DNS or certificate-transparency logs individually.

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager" # baseline PSA is fine; no opt-out labels needed
  }
}

resource "helm_release" "cert_manager" {
  depends_on = [helm_release.cilium]

  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.cert_manager_chart_version
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  values = [yamlencode({
    crds = { enabled = true }
    # FW-015 limits workload egress to tcp 80/443, so the DNS-01 self-check
    # cannot query authoritative nameservers on :53 directly. Route all
    # propagation checks through the internal Technitium resolvers (FW-001).
    dns01RecursiveNameservers     = "10.0.10.4:53,10.0.10.5:53"
    dns01RecursiveNameserversOnly = true
  })]
}

resource "kubernetes_secret" "cloudflare_api_token" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace.cert_manager.metadata[0].name
  }
  data = {
    api-token = data.azurerm_key_vault_secret.cloudflare_dns_api_token.value
  }
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
              apiTokenSecretRef = {
                name = kubernetes_secret.cloudflare_api_token.metadata[0].name
                key  = "api-token"
              }
            }
          }
        }]
      }
    }
  })
}
