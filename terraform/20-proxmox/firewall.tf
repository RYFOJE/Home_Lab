# Layer-2 rules from documentation/networking/firewall_rules.yaml (PVE-FW-* /
# LXC-FW-*). Rule data lives in terraform.tfvars; this file only wires it to
# the module and attaches each LXC group's security group to its vNICs.
#
# The k8s VM vNICs stay firewall=0 (see vms.tf) -- datacenter default-deny
# never touches them.

module "firewall" {
  source = "./modules/firewall"

  cluster_options = var.firewall_cluster_options
  ipsets          = var.firewall_ipsets
  security_groups = var.firewall_security_groups
  cluster_rules   = var.firewall_cluster_rules

  # LXC-FW-001..006 via the core-infra security group, LXC-FW-007..008 via the
  # agent one; input DROP is PVE-FW-900 applied at the CT vNIC. Building this
  # from the container resources orders firewall config after the CTs exist.
  guests = merge(
    {
      for name, ct in proxmox_virtual_environment_container.core_infra : name => {
        node_name       = ct.node_name
        container_id    = ct.vm_id
        security_groups = var.core_infra_security_groups
        input_policy    = "DROP"
        output_policy   = "ACCEPT"
      }
    },
    {
      for name, ct in proxmox_virtual_environment_container.azdo_agent : name => {
        node_name       = ct.node_name
        container_id    = ct.vm_id
        security_groups = var.azdo_agent_security_groups
        input_policy    = "DROP"
        output_policy   = "ACCEPT"
      }
    },
  )
}
