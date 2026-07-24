resource "kubernetes_namespace" "longhorn_system" {
  metadata {
    name = "longhorn-system"
    # Longhorn needs privileged pods; Talos enforces baseline cluster-wide,
    # so opt this namespace out via PSA labels.
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "longhorn" {
  # cilium: on a fresh rebuild nodes are NotReady until the CNI lands.
  depends_on = [kubectl_manifest.storage_network, helm_release.cilium]

  name       = "longhorn"
  repository = "https://charts.longhorn.io"
  chart      = "longhorn"
  version    = var.longhorn_chart_version
  namespace  = kubernetes_namespace.longhorn_system.metadata[0].name

  values = [yamlencode({
    defaultSettings = {
      # Shares the OS disk -- bind-mounted by 30-talos kubelet extraMounts.
      defaultDataPath = "/var/lib/longhorn"
      # Replica/engine traffic over the Multus VLAN 12 attachment.
      storageNetwork = "${kubernetes_namespace.longhorn_system.metadata[0].name}/storage-network"
      # Node prereqs (hugepages + kernel modules) baked in by 30-talos.
      v2DataEngine = var.longhorn_v2_data_engine
    }
  })]
}
