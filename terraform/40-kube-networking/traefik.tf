# Two Traefik instances split the edge by exposure (wifi_and_isolation.md §4):
#   external -- 10.1.11.50, the Cloudflare Tunnel origin
#   internal -- 10.1.11.51, LAN-only, never port-forwarded
# Apps pick one via ingressClass. Internal-only apps are unreachable from the
# WAN by topology (no route to .51 exists from outside), not by per-route
# configuration.
#
# Each instance is a namespace + helm release + wildcard cert + containment
# NetworkPolicy -- bundled in ./modules/traefik-instance. Shared values live in
# values/traefik.yaml so CI renders exactly what Terraform applies.

locals {
  # Cloudflare published IPv4 edge ranges (https://www.cloudflare.com/ips-v4)
  # -- static for years, reviewed on change. The external instance trusts
  # client-IP headers from these; the module adds its own pod CIDR (the
  # cloudflared pod is the direct peer in tunnel mode, and the real client IP
  # arrives in CF-Connecting-IP / X-Forwarded-For).
  cloudflare_ipv4 = [
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
  ]

  traefik_base_values = file("${path.module}/values/traefik.yaml")
}

# CRDs as their own release, from the chart Traefik publishes for exactly this.
# Helm does not upgrade a chart's crds/ directory on `helm upgrade` -- ever --
# so the CRDs bundled with the traefik chart would install once at first apply
# and then stay frozen while the chart moved on. Both instances set
# skip_crds = true and take their CRDs from here instead.
#
# The version tracks the traefik chart: traefik-crds is republished only when
# the CRDs themselves change, so its number lags and is pinned separately.
#
# The release needs a namespace of its own -- it renders no namespaced objects,
# but helm still records the release secret in one -- and, like every namespace
# in this cluster, a PSA label: kyverno-policies denies an unlabelled namespace
# on UPDATE as well as CREATE.
resource "kubernetes_namespace" "traefik_crds" {
  metadata {
    name = "traefik-crds"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "helm_release" "traefik_crds" {
  depends_on = [helm_release.cilium]

  name             = "traefik-crds"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik-crds"
  version          = var.traefik_crds_chart_version
  namespace        = kubernetes_namespace.traefik_crds.metadata[0].name
  create_namespace = false
  timeout          = 600
}

module "traefik_external" {
  source = "./modules/traefik-instance"

  instance_name = "external"
  lb_ip         = "10.1.11.50"
  public_domain = data.azurerm_key_vault_secret.public_domain.value
  chart_version = var.traefik_chart_version
  base_values   = local.traefik_base_values

  forwarded_headers_trusted_ips = local.cloudflare_ipv4

  depends_on = [
    helm_release.cilium,
    helm_release.traefik_crds,
    kubectl_manifest.letsencrypt_issuer,
    # values/traefik.yaml names platform-critical (scheduling.tf).
    local.priority_classes,
  ]
}

module "traefik_internal" {
  source = "./modules/traefik-instance"

  instance_name = "internal"
  lb_ip         = "10.1.11.51"
  public_domain = data.azurerm_key_vault_secret.public_domain.value
  chart_version = var.traefik_chart_version
  base_values   = local.traefik_base_values

  depends_on = [
    helm_release.cilium,
    helm_release.traefik_crds,
    kubectl_manifest.letsencrypt_issuer,
    local.priority_classes,
  ]
}
