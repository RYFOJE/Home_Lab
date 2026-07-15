variable "kubeconfig_path" {
  description = "Path to the kubeconfig pulled from the k3s cluster (API via kube-vip at 10.1.11.10)"
  type        = string
  default     = "~/.kube/config"
}
