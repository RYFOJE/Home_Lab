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

  # Literal dots escaped for the Go regexp the fallback route matches on.
  public_domain_regexp = replace(data.azurerm_key_vault_secret.public_domain.value, ".", "\\.")

  # Named in two objects: the ServersTransport itself and the route's reference
  # to it. Traefik resolves an unknown transport name at request time, so a
  # mismatch surfaces as a 500 rather than a failed apply.
  lan_fallback_transport = "traefik-external-wildcard"
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
  depends_on = [data.talos_cluster_health.post_cilium]

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
    data.talos_cluster_health.post_cilium,
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
    data.talos_cluster_health.post_cilium,
    helm_release.traefik_crds,
    kubectl_manifest.letsencrypt_issuer,
    local.priority_classes,
  ]
}

# LAN fallback. Internal DNS resolves the public domain to one address --
# 10.1.11.51, a wildcard plus an apex record and nothing else (allocations.md)
# -- so the internal instance answers for every LAN request and has to serve
# routes it does not own. This is the lowest-priority route on that instance:
# anything under the public domain with no route of its own falls through to
# the external instance, which carries the public apps. Without it, an app
# published on traefik-external is unreachable from the LAN.
#
# Direction is load-bearing. internal -> external only: the reverse would put
# internal-only routes in the tunnel origin's routing table and publish them.
#
# Both objects live in the external namespace; the route names the internal
# instance's ingressClass. Instances are separated by class alone -- neither
# restricts providers.kubernetesCRD.namespaces -- so the internal instance
# still picks the route up, while its Service and ServersTransport references
# stay same-namespace and no allowCrossNamespace is needed on either instance.
resource "kubectl_manifest" "lan_fallback_transport" {
  depends_on = [helm_release.traefik_crds, module.traefik_external]

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "ServersTransport"
    metadata = {
      name      = local.lan_fallback_transport
      namespace = module.traefik_external.namespace
    }
    spec = {
      # SNI pinned to the apex so the wildcard cert's apex SAN validates on the
      # second hop; the cert is publicly trusted, so verification stays on.
      # Same reasoning as 50-cloudflare's origin_server_name.
      serverName = data.azurerm_key_vault_secret.public_domain.value
    }
  })
}

resource "kubectl_manifest" "lan_fallback_route" {
  depends_on = [kubectl_manifest.lan_fallback_transport, module.traefik_internal]

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "lan-fallback"
      namespace = module.traefik_external.namespace
    }
    spec = {
      # The spec field, not the kubernetes.io/ingress.class annotation: Traefik
      # reads the annotation only as a deprecated fallback and warns on every
      # provider refresh when it does.
      ingressClassName = module.traefik_internal.ingress_class
      entryPoints      = ["websecure"]
      routes = [{
        kind = "Rule"
        # Scoped to the public domain rather than `.+`: a request carrying an
        # unrelated Host gets a 404 here instead of being proxied onward.
        match = "HostRegexp(`^(.+\\.)?${local.public_domain_regexp}$`)"
        # 1, not 0: priority 0 is ignored and falls back to rule-length
        # sorting, which would out-rank the Host() rules this must never
        # shadow. Real routes sort in the 20-40 range.
        priority = 1
        services = [{
          # Service name == namespace for both instances (module naming).
          # Port 443 is the Service port; the chart maps it to websecure
          # (container 8443). Never port 80 -- the global web -> websecure
          # redirect would bounce the client back to the LAN wildcard and loop.
          name             = module.traefik_external.namespace
          port             = 443
          scheme           = "https"
          serversTransport = local.lan_fallback_transport
        }]
      }]
      # No secretName: the internal instance's default wildcard cert is served.
      tls = {}
    }
  })
}
