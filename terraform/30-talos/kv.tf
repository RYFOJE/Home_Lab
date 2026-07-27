# Admin access that survives the loss of this layer's state.
#
# talos_machine_secrets is the cluster's root of trust, and it exists in
# exactly one place: 30-talos.tfstate. Lose that file and the machine secrets
# are gone for good -- there is no way to regenerate them and no way to derive
# a working talosconfig, so a cluster that is still running becomes one nobody
# can administer or reinstall in place. The secrets themselves cannot be
# rescued, but the two client credentials derived from them can, and having
# them is the difference between "rebuild state against a live cluster" and
# "wipe three nodes and start at 20-proxmox".
#
# Key Vault is already the trust anchor for this homelab (documentation/
# secrets.md), so this puts nothing anywhere that was not already trusted with
# the ArgoCD admin hash and the ESO service principal. Both values are equally
# sensitive wherever they sit: they are already in Terraform state in the
# clear, which is why the state backend is the thing to protect first
# (documentation/infrastructure/disaster_recovery.md, "State backend hardening").
#
# Layer 40 consumes both client configurations through terraform_remote_state
# for its post-Cilium health gate. The kubeconfig also has one automated reader
# outside Terraform -- ansible/azdo-agent.yml uses it for a single
# `kubectl get secret` on the control node
# (documentation/infrastructure/azdo_agents.md).
#
# Unprefixed names: the `<namespace>--<name>` convention applies to secrets ESO
# syncs into the cluster. These are never synced -- reading them is otherwise a
# break-glass action performed by an operator with `az keyvault secret show`.

provider "azurerm" {
  features {}
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

# talosctl --talosconfig <this> -- node-level control of all three machines.
resource "azurerm_key_vault_secret" "talosconfig" {
  name         = "talos-talosconfig"
  value        = data.talos_client_configuration.this.talos_config
  key_vault_id = data.azurerm_key_vault.this.id

  content_type = "talosconfig (yaml)"
  tags = {
    layer   = "30-talos"
    purpose = "break-glass admin access; see disaster_recovery.md"
  }
}

# kubectl --kubeconfig <this> -- cluster-admin on the kube API. Depends on the
# bootstrap having completed (talos_cluster_kubeconfig already does), so on a
# fresh build this lands only once the API is actually up.
resource "azurerm_key_vault_secret" "kubeconfig" {
  name         = "talos-kubeconfig"
  value        = talos_cluster_kubeconfig.this.kubeconfig_raw
  key_vault_id = data.azurerm_key_vault.this.id

  content_type = "kubeconfig (yaml)"
  tags = {
    layer   = "30-talos"
    purpose = "break-glass admin access; see disaster_recovery.md"
  }
}
