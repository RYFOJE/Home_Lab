variable "unifi_api_url" {
  description = "URL of the UniFi controller API (e.g. https://10.0.10.1/)"
  type        = string
}

variable "unifi_username" {
  description = "Local UniFi controller user for Terraform (not a Ubiquiti cloud account)"
  type        = string
}

variable "unifi_password" {
  description = "Password for the Terraform controller user"
  type        = string
  sensitive   = true
}

variable "unifi_insecure" {
  description = "Skip TLS verification for the controller (true if using a self-signed cert)"
  type        = bool
  default     = true
}
