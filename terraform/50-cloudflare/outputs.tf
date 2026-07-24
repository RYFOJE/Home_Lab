output "tunnel_id" {
  description = "Cloudflare Tunnel UUID."
  value       = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

output "tunnel_cname" {
  description = "CNAME target for the public records (<tunnel-id>.cfargotunnel.com)."
  value       = local.tunnel_cname
}
