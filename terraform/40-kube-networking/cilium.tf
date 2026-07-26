# Cilium is the cluster's networking stack in one component: CNI, NetworkPolicy
# enforcement, kube-proxy replacement, LoadBalancer IPAM, and L2 announcements
# for the pool in allocations.md. 30-talos sets
# cluster.network.cni = none and cluster.proxy.disabled = true; nothing works
# until this release is applied, so everything else in this layer depends on it.
#
# Values live in values/cilium.yaml -- read here and by
# scripts/check_cluster_policy.py, so CI renders the chart with exactly what
# Terraform applies rather than with chart defaults.

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_chart_version
  namespace  = "kube-system"

  # Installing the CNI on a fresh cluster waits on every node's agent coming up
  # behind an image pull. The provider's 300s default is not enough for that on
  # a cold rebuild, and a timeout leaves a half-applied release behind.
  timeout = 900

  values = [file("${path.module}/values/cilium.yaml")]
}

# LoadBalancer pool per allocations.md: 10.1.11.50 - 10.1.11.249 on VLAN 11.
#
# cilium.io/v2, not v2alpha1: this CRD was promoted to v2 in Cilium 1.16 and the
# v2alpha1 version was dropped in 1.18 (v1.19.6 ships only
# crds/v2/ciliumloadbalancerippools.yaml). The L2 announcement policy below is
# deliberately still v2alpha1 -- it has not been promoted -- so the two api
# versions differing here is correct, not an oversight. Re-check both on a
# Cilium major bump.
resource "kubectl_manifest" "lb_pool" {
  depends_on = [helm_release.cilium]

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumLoadBalancerIPPool"
    metadata   = { name = "vlan11-pool" }
    spec = {
      blocks = [{ start = "10.1.11.50", stop = "10.1.11.249" }]
    }
  })
}

# Announce LB IPs on eth0 (VLAN 11) only. eth1 is the VLAN 12 storage island
# and must never answer ARP for edge addresses.
#
# Still cilium.io/v2alpha1 in 1.19 -- unlike the pool above, this kind has not
# been promoted. Do not "align" the two.
#
# Every Service announced through this policy must keep
# externalTrafficPolicy: Cluster. Cilium documents L2 announcements as
# incompatible with `Local`: the lease holder answers ARP for the IP regardless
# of whether it runs a backend, so a `Local` Service is silently black-holed on
# every node that does not (values/traefik.yaml).
resource "kubectl_manifest" "l2_announcements" {
  depends_on = [helm_release.cilium]

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata   = { name = "vlan11-l2" }
    spec = {
      interfaces      = ["^eth0$"]
      loadBalancerIPs = true
      externalIPs     = false
    }
  })
}
