# The tunnel token flows to the in-cluster cloudflared workload
# (kubernetes/apps/cloudflared, deployed by ArgoCD) through the standard ESO
# path: Terraform writes it to Key Vault under the cloudflared namespace
# prefix, and the app's ExternalSecret syncs it in. This is the only secret
# Terraform WRITES to the vault -- everything else it only reads.
#
# Token rotation (tunnel_secret replacement) updates the vault value; ESO
# re-syncs within refreshInterval, but running pods only read TUNNEL_TOKEN at
# start -- follow with `kubectl -n cloudflared rollout restart deploy/cloudflared`.
resource "azurerm_key_vault_secret" "cloudflared_tunnel_token" {
  name         = "cloudflared--tunnel-token"
  key_vault_id = data.azurerm_key_vault.this.id
  value        = data.cloudflare_zero_trust_tunnel_cloudflared_token.homelab.token
  content_type = "cloudflared TUNNEL_TOKEN (written by terraform/50-cloudflare)"
}
