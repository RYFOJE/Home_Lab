# Two Traefik instances split the edge by exposure (wifi_and_isolation.md §4):
#   external -- 10.1.11.50, the router's only WAN DNAT target
#   internal -- 10.1.11.51, LAN-only, never port-forwarded
# Apps pick one via ingressClass. Internal-only apps are unreachable from the
# WAN by topology (no DNAT exists to .51), not by per-route configuration.
#
# Each instance is a namespace + helm release + wildcard cert + containment
# NetworkPolicy -- bundled in ./modules/traefik-instance. The external instance
# installs the shared Traefik CRDs; the internal one is ordered after it and
# skips them.

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
}

module "traefik_external" {
  source = "./modules/traefik-instance"

  instance_name = "external"
  lb_ip         = "10.1.11.50"
  public_domain = data.azurerm_key_vault_secret.public_domain.value
  chart_version = var.traefik_chart_version
  install_crds  = true

  forwarded_headers_trusted_ips = local.cloudflare_ipv4

  depends_on = [helm_release.cilium, kubectl_manifest.letsencrypt_issuer]
}

module "traefik_internal" {
  source = "./modules/traefik-instance"

  instance_name = "internal"
  lb_ip         = "10.1.11.51"
  public_domain = data.azurerm_key_vault_secret.public_domain.value
  chart_version = var.traefik_chart_version
  install_crds  = false

  # After external so the shared CRDs exist before this release's TLSStore.
  depends_on = [module.traefik_external, kubectl_manifest.letsencrypt_issuer]
}
