# Cloudflare Tunnel: the WAN entry for the public edge (wifi_and_isolation.md
# §4). cloudflared pods (cloudflared.tf) dial OUT to the Cloudflare edge (udp
# 7844 QUIC, FW-015) and proxy inbound requests to the external Traefik
# instance -- no WAN port-forward exists in tunnel mode.

resource "random_bytes" "tunnel_secret" {
  length = 32 # API minimum; .base64 is exactly the encoding tunnel_secret wants
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id = local.account_id
  name       = var.tunnel_name
  # Remote-managed: the config lives in the _config resource below, not in a
  # local cloudflared config file. Never edit the tunnel in the ZT dashboard --
  # dashboard edits fight the Terraform-owned remote config.
  config_src    = "cloudflare"
  tunnel_secret = random_bytes.tunnel_secret.base64
}

locals {
  tunnel_cname = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  # 40-Kube-Networking names the external Traefik namespace, helm release, and Service all
  # "traefik-<name>", so service == namespace here (:443 = websecure entry).
  origin_service = "https://${var.traefik_external_namespace}.${var.traefik_external_namespace}.svc.cluster.local:443"
  origin_request = {
    # SNI pinned to the apex so the wildcard cert's apex SAN validates -- the
    # LE cert is publicly trusted, so full verification stays on.
    origin_server_name = local.domain
    no_tls_verify      = false
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id

  config = {
    ingress = [
      {
        hostname       = local.domain
        service        = local.origin_service
        origin_request = local.origin_request
      },
      {
        hostname       = "*.${local.domain}"
        service        = local.origin_service
        origin_request = local.origin_request
      },
      # Mandatory catch-all: anything not matching the zone's hostnames.
      {
        service = "http_status:404"
      },
    ]
  }
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "homelab" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}
