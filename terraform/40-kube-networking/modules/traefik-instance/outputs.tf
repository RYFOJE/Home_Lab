output "namespace" {
  description = "Namespace of this instance. The helm release and Service share the name, so downstream consumers build the Service FQDN as <namespace>.<namespace>.svc.cluster.local."
  value       = kubernetes_namespace.this.metadata[0].name
}

output "ingress_class" {
  description = "IngressClass this instance watches. Routes are bound to an instance by this value alone -- both instances watch every namespace."
  value       = local.ingress_class
}
