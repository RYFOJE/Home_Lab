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
    name = local.name
    # Baseline PSA; Traefik is non-root on 8000/8443. Declared explicitly
    # because kyverno-policies' require-namespace-psa-label denies any
    # namespace without an enforce label -- on CREATE and on UPDATE, so an
    # unlabelled namespace would be frozen against future Terraform edits.
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

resource "helm_release" "this" {
  name       = local.name
  repository = var.chart_repository
  chart      = "traefik"
  version    = var.chart_version
  namespace  = kubernetes_namespace.this.metadata[0].name

  # CRDs come from the separate traefik-crds release (traefik.tf). Helm never
  # upgrades anything in a chart's crds/ directory on `helm upgrade`, so the
  # bundled copy would install once and then diverge from the chart on every
  # later bump. Both instances skip them.
  skip_crds = true

  # Longhorn-sized installs are not the issue here, but the 300s provider
  # default is short enough that a first apply on a cold node (image pull plus
  # LB IP assignment) can time out and leave a partial release behind.
  timeout = 600

  # Everything shared by both instances lives in values/traefik.yaml, which CI
  # renders against the chart's schema before merge. Only the values that
  # genuinely differ per instance are built here.
  values = [
    var.base_values,
    yamlencode(merge(
      {
        service = {
          annotations = { "lbipam.cilium.io/ips" = var.lb_ip }
        }
        ingressClass = {
          name = local.ingress_class
        }
        providers = {
          # Each instance watches only its own class -- routes never leak
          # between the internal and external entry points.
          kubernetesCRD     = { ingressClass = local.ingress_class }
          kubernetesIngress = { ingressClass = local.ingress_class }
        }
      },
      # Trust client-IP headers only from the declared upstream proxies
      # (Cloudflare edge / cloudflared pod); see traefik.tf. Empty list =
      # feature off, and no `forwardedHeaders` key is emitted at all.
      length(local.trusted_ips) > 0 ? {
        ports = {
          web       = { forwardedHeaders = { trustedIPs = local.trusted_ips } }
          websecure = { forwardedHeaders = { trustedIPs = local.trusted_ips } }
        }
      } : {}
    )),
  ]
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
