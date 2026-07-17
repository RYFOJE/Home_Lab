variable "instance_name" {
  description = "Exposure name for this instance (e.g. \"external\", \"internal\"). Drives the namespace, helm release name, and ingressClass (all \"traefik-<name>\")."
  type        = string
}

variable "lb_ip" {
  description = "LoadBalancer IP from the Cilium pool to pin this instance's Service to (allocations.md)."
  type        = string
}

variable "public_domain" {
  description = "Owned public domain; the wildcard Certificate covers <domain> and *.<domain>."
  type        = string
}

variable "install_crds" {
  description = "Whether this instance's helm release installs the shared Traefik CRDs. Exactly one instance sets true; the rest set false and are ordered after it via module depends_on."
  type        = bool
  default     = false
}

variable "chart_repository" {
  description = "Traefik helm chart repository."
  type        = string
  default     = "https://traefik.github.io/charts"
}

variable "workloads_cidr" {
  description = "VLAN 11 subnet the kube API endpoints live on; egress allow for route/secret watches (allocations.md)."
  type        = string
  default     = "10.1.11.0/24"
}

variable "pod_cidr" {
  description = "Pod overlay CIDR; egress allow for proxied in-cluster backends (allocations.md)."
  type        = string
  default     = "10.1.200.0/22"
}

variable "forwarded_headers_trusted_ips" {
  description = "CIDRs whose X-Forwarded-* / CF-Connecting-IP headers Traefik trusts on the web/websecure entry points. External instance: Cloudflare edge ranges plus the pod CIDR (the cloudflared pod is the direct peer in tunnel mode). Empty list = feature off (internal instance)."
  type        = list(string)
  default     = []
}
