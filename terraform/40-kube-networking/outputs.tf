output "traefik_external_namespace" {
  description = "Namespace (= Service name) of the external Traefik instance. Consumed by 50-cloudflare to build the tunnel origin FQDN instead of duplicating the name."
  value       = module.traefik_external.namespace
}

output "traefik_internal_namespace" {
  description = "Namespace (= Service name) of the internal Traefik instance."
  value       = module.traefik_internal.namespace
}
