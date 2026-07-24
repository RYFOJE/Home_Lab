output "namespace" {
  description = "Namespace of this instance. The helm release and Service share the name, so downstream consumers build the Service FQDN as <namespace>.<namespace>.svc.cluster.local."
  value       = kubernetes_namespace.this.metadata[0].name
}
