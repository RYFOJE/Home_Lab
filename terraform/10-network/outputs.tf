# Single source of truth for the public edge mode. 50-cloudflare reads this
# via terraform_remote_state instead of carrying its own copy -- flip it in
# ONE place (terraform.tfvars here), then apply 10-network followed by
# 50-cloudflare.
output "edge_mode" {
  description = "Public edge mode (\"tunnel\" | \"dnat\"); consumed by 50-cloudflare."
  value       = var.edge_mode
}
