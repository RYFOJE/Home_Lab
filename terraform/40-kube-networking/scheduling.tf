# Scheduling priority for the workloads this repo owns.
#
# Without these every pod sits at priority 0, so under node pressure the
# kubelet's eviction order and the scheduler's preemption order are decided by
# resource usage alone -- an oversized Loki query can evict the ingress
# controller, and a Pending pod cannot displace anything. On three nodes with a
# fixed workload that is the realistic failure mode, not bin-packing.
#
# Owned by Terraform, not by a GitOps app, because the first consumers are
# Terraform's own releases: cert-manager and both Traefik instances in this
# layer, and ArgoCD in 60-argo-cd. A pod naming a PriorityClass that does not
# exist is rejected by the Priority admission plugin, so an ArgoCD-created class
# would be unreachable for the very release that installs ArgoCD -- it could
# never start, and nothing would ever create the class. Same reason the
# external-secrets namespace is Terraform-owned (60-argo-cd/gitops.tf): it has
# to exist before the thing that would otherwise create it.
#
# This layer rather than an earlier one because it is the first with a
# kubernetes provider, and the classes need only the API server -- they are
# created before Cilium and depend on nothing in it.
#
# Three tiers, deliberately few. A priority scheme with more levels than there
# are real decisions is one nobody applies consistently.
#
# globalDefault stays false on all three: setting it would silently reprice
# every pod in the cluster, including ones in namespaces this repo does not
# manage. A workload opts in by naming a class.
#
# Values sit far below the built-in system-cluster-critical (2000000000) and
# system-node-critical (2000001000), so nothing here can outrank the control
# plane, Cilium, or CoreDNS. Longhorn is deliberately absent: its chart ships
# and assigns its own longhorn-critical class.

# Losing one of these is an outage, not a degradation: no ingress, no
# certificates, no secrets reaching the cluster, no GitOps, no database.
resource "kubernetes_priority_class" "platform_critical" {
  metadata {
    name = "platform-critical"
  }
  value       = 100000
  description = "Ingress, certificate issuance, secret sync, GitOps control and the database. Preempts everything below it."
}

# The cluster keeps serving without these, but nobody can see that it does.
resource "kubernetes_priority_class" "platform_observability" {
  metadata {
    name = "platform-observability"
  }
  value       = 10000
  description = "Metrics, alerting and the Grafana UI. Survives pressure that evicts ordinary workloads, yields to platform-critical."
}

# Explicitly below the default 0, so these are the first thing preempted and
# they never displace anything. Log and trace ingestion is the part of the stack
# whose gaps are recoverable.
resource "kubernetes_priority_class" "platform_bulk" {
  metadata {
    name = "platform-bulk"
  }
  value             = -100
  preemption_policy = "Never"
  description       = "Log and trace ingestion and shipping. First to be evicted under node pressure and never preempts anything."
}

locals {
  # Every release in this layer or later that names a platform-* class has to be
  # ordered after all three -- the admission rejection is per pod, at creation.
  priority_classes = [
    kubernetes_priority_class.platform_critical,
    kubernetes_priority_class.platform_observability,
    kubernetes_priority_class.platform_bulk,
  ]
}
