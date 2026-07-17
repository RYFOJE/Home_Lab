# Multus + whereabouts give Longhorn a second pod interface on VLAN 12 (eth1)
# so replica/engine traffic stays on the storage island.
#
# Installed from vendored upstream release manifests (manifests/, images pinned)
# via kubectl_manifest -- the k8snetworkplumbingwg org publishes no helm repo.
# kubectl_manifest also sidesteps kubernetes_manifest's plan-time CRD lookup,
# so a fresh cluster applies in one pass (no -target staging).

data "kubectl_file_documents" "multus" {
  content = file("${path.module}/manifests/multus-daemonset-thick.yaml")
}

resource "kubectl_manifest" "multus" {
  # Multus delegates the primary CNI config from /etc/cni/net.d -- Cilium must
  # have written it first (also: no pods schedule before the CNI is up).
  depends_on = [helm_release.cilium]

  for_each          = data.kubectl_file_documents.multus.manifests
  yaml_body         = each.value
  server_side_apply = true
  wait              = true
}

data "kubectl_file_documents" "whereabouts" {
  content = join("\n---\n", [
    file("${path.module}/manifests/whereabouts-whereabouts.cni.cncf.io_ippools.yaml"),
    file("${path.module}/manifests/whereabouts-whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml"),
    file("${path.module}/manifests/whereabouts-whereabouts.cni.cncf.io_nodeslicepools.yaml"),
    file("${path.module}/manifests/whereabouts-daemonset-install.yaml"),
  ])
}

resource "kubectl_manifest" "whereabouts" {
  depends_on = [helm_release.cilium]

  for_each          = data.kubectl_file_documents.whereabouts.manifests
  yaml_body         = each.value
  server_side_apply = true
  wait              = true
}

resource "kubectl_manifest" "storage_network" {
  depends_on = [kubectl_manifest.multus, kubectl_manifest.whereabouts]

  yaml_body = yamlencode({
    apiVersion = "k8s.cni.cncf.io/v1"
    kind       = "NetworkAttachmentDefinition"
    metadata = {
      name      = "storage-network"
      namespace = kubernetes_namespace.longhorn_system.metadata[0].name
    }
    spec = {
      config = jsonencode({
        cniVersion = "0.3.1"
        type       = "macvlan"
        master     = "eth1" # VLAN 12 NIC from 20-proxmox / 30-talos
        mode       = "bridge"
        # Jumbo frames per allocations.md; eth1 itself is set to 9000 by 30-talos.
        mtu = var.storage_network_mtu
        ipam = {
          type  = "whereabouts"
          range = var.storage_network_cidr
          # Keep node eth1 IPs (and the unused .1) out of the pod range.
          exclude = concat(
            [for ip in values(local.node_storage_ips) : "${ip}/32"],
            ["${cidrhost(var.storage_network_cidr, 1)}/32"],
          )
        }
      })
    }
  })
}
