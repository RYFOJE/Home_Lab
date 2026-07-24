# Layer-2 rules from documentation/networking/firewall_rules.yaml (PVE-FW-* /
# LXC-FW-*). Rule data lives in terraform.tfvars; this file only wires it to
# the module and attaches the core-infra security group to each LXC.
#
# The k8s VM vNICs stay firewall=0 (see vms.tf) -- datacenter default-deny
# never touches them.

module "firewall" {
  source = "./modules/firewall"

  cluster_options = var.firewall_cluster_options
  ipsets          = var.firewall_ipsets
  security_groups = var.firewall_security_groups
  cluster_rules   = var.firewall_cluster_rules

  # LXC-FW-001..005 via the core-infra security group; input DROP is
  # PVE-FW-900 applied at the CT vNIC. Building this from the container
  # resources orders firewall config after the CTs exist.
  guests = {
    for name, ct in proxmox_virtual_environment_container.core_infra : name => {
      node_name       = ct.node_name
      container_id    = ct.vm_id
      security_groups = var.core_infra_security_groups
      input_policy    = "DROP"
      output_policy   = "ACCEPT"
    }
  }
}
