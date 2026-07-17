# One Traefik ingress instance: namespace + helm release + wildcard cert + a
# default-deny containment NetworkPolicy. Exposure differs only by lb_ip and
# ingressClass; see traefik.tf for how the external/internal split is used and
# wifi_and_isolation.md §4 for the design.

locals {
  name          = "traefik-${var.instance_name}"
  ingress_class = "traefik-${var.instance_name}"

  # When header trust is enabled, the pod CIDR is always a trusted upstream
  # (the direct peer is an in-cluster pod: cloudflared in tunnel mode). The
  # caller passes only the external ranges; the module owns pod_cidr. Empty
  # list = feature off, so no IPs are trusted.
  trusted_ips = length(var.forwarded_headers_trusted_ips) > 0 ? concat(var.forwarded_headers_trusted_ips, [var.pod_cidr]) : []
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = local.name # baseline PSA; Traefik is non-root on 8000/8443
  }
}

resource "helm_release" "this" {
  name       = local.name
  repository = var.chart_repository
  chart      = "traefik"
  namespace  = kubernetes_namespace.this.metadata[0].name

  # All instances ship identical CRDs; only the designated one installs them.
  skip_crds = !var.install_crds

  values = [yamlencode({
    service = {
      annotations = { "lbipam.cilium.io/ips" = var.lb_ip }
      # Preserve client source IPs (access logs, allowlist middlewares).
      spec = { externalTrafficPolicy = "Local" }
    }
    ingressClass = {
      enabled        = true
      isDefaultClass = false
      name           = local.ingress_class
    }
    providers = {
      # Each instance watches only its own class -- routes never leak between
      # the internal and external entry points.
      kubernetesCRD     = { ingressClass = local.ingress_class }
      kubernetesIngress = { ingressClass = local.ingress_class }
    }
    ports = merge(
      {
        web = merge(
          {
            redirections = {
              entryPoint = { to = "websecure", scheme = "https", permanent = true }
            }
          },
          # Trust client-IP headers only from the declared upstream proxies
          # (Cloudflare edge / cloudflared pod); see traefik.tf.
          length(local.trusted_ips) > 0
          ? { forwardedHeaders = { trustedIPs = local.trusted_ips } } : {}
        )
      },
      length(local.trusted_ips) > 0
      ? { websecure = { forwardedHeaders = { trustedIPs = local.trusted_ips } } } : {}
    )
    # Serve the wildcard cert for any TLS route with no explicit cert.
    tlsStore = {
      default = { defaultCertificate = { secretName = "wildcard-tls" } }
    }
    ingressRoute = {
      dashboard = { enabled = false }
    }
  })]
}

# Wildcard cert, one per namespace (Secrets are namespace-local).
resource "kubectl_manifest" "wildcard_certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "wildcard"
      namespace = kubernetes_namespace.this.metadata[0].name
    }
    spec = {
      secretName = "wildcard-tls"
      issuerRef  = { name = "letsencrypt", kind = "ClusterIssuer" }
      dnsNames   = [var.public_domain, "*.${var.public_domain}"]
    }
  })
}

# Containment (wifi_and_isolation.md §4): default-deny around the edge pods,
# enforced by Cilium. Inbound only on the entry points; outbound only to the
# kube API, cluster DNS, and in-cluster app pods -- no internet egress (ACME
# is DNS-01 via cert-manager, so Traefik itself never talks out).
resource "kubernetes_network_policy" "containment" {
  metadata {
    name      = "traefik-containment"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      ports {
        port     = 8000 # web entry point (container-side of :80)
        protocol = "TCP"
      }
      ports {
        port     = 8443 # websecure entry point (container-side of :443)
        protocol = "TCP"
      }
    }

    egress {
      # Cluster DNS (CoreDNS in kube-system).
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports {
        port     = 53
        protocol = "UDP"
      }
      ports {
        port     = 53
        protocol = "TCP"
      }
    }

    egress {
      # kube API: watches for Ingress/IngressRoute/Services/Secrets land on a
      # node API endpoint (6443) or KubePrism (7445) after service translation.
      to {
        ip_block { cidr = var.workloads_cidr }
      }
      ports {
        port     = 6443
        protocol = "TCP"
      }
      ports {
        port     = 7445
        protocol = "TCP"
      }
    }

    egress {
      # Proxied backends: in-cluster app pods only (Pod CIDR, allocations.md).
      to {
        ip_block { cidr = var.pod_cidr }
      }
    }
  }
}
