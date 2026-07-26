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

  # Longhorn routinely exceeds the provider's 300s default on first install:
  # the manager DaemonSet, the CSI sidecars and the instance managers all pull
  # before the release reports ready. A timeout leaves a partial install that
  # has to be cleaned up by hand.
  timeout = 900

  values = [
    # Static values, rendered by scripts/check_cluster_policy.py in CI.
    file("${path.module}/values/longhorn.yaml"),
    # The v2 data engine's node prerequisites (hugepages, nvme_tcp/vfio_pci/
    # uio_pci_generic modules) are set by 30-talos, and reserving hugepages
    # costs 2 GiB of RAM per node whether or not the engine runs. The flag
    # therefore lives with the prerequisites it gates and is read from that
    # layer's state, rather than being a second switch here that can disagree
    # with them.
    yamlencode({
      defaultSettings = {
        v2DataEngine = local.longhorn_v2_data_engine
      }
    }),
  ]
}
