# Cilium is the cluster's networking stack in one component: CNI, NetworkPolicy
# enforcement, kube-proxy replacement, LoadBalancer IPAM, and L2 announcements
# for the pool in allocations.md. 30-talos sets
# cluster.network.cni = none and cluster.proxy.disabled = true; nothing works
# until this release is applied, so everything else in this layer depends on it.

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_chart_version
  namespace  = "kube-system"

  values = [yamlencode({
    # Use the per-node podCIDRs Kubernetes carves from 10.1.200.0/22 (30-talos),
    # keeping the documented 4-node capacity semantics.
    ipam = { mode = "kubernetes" }

    # kube-proxy is disabled in the Talos machine config; Cilium takes over.
    # API access goes through KubePrism (Talos-local balancer, default-on).
    kubeProxyReplacement = true
    k8sServiceHost       = "localhost"
    k8sServicePort       = 7445

    # Talos requirements (no privileged init relabeling, cgroup v2 pre-mounted).
    securityContext = {
      capabilities = {
        ciliumAgent = [
          "CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN",
          "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID",
        ]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }
    cgroup = {
      autoMount = { enabled = false }
      hostRoot  = "/sys/fs/cgroup"
    }

    # ARP-based announcement of LoadBalancer IPs on VLAN 11 (lease-based; the
    # raised client rate limit is the documented prerequisite for the leases).
    l2announcements    = { enabled = true }
    k8sClientRateLimit = { qps = 20, burst = 40 }

    # The chart creates a `cilium-secrets` Namespace of its own
    # (tls.secretsNamespace.create defaults true) to hold TLS material for
    # CiliumEnvoyConfig. Nothing schedules there, so baseline matches the rest
    # of the cluster. The label is not optional: kyverno-policies'
    # require-namespace-psa-label denies a namespace with no enforce label on
    # UPDATE as well as CREATE, so without it any later chart bump that touches
    # this object is refused fail-closed and the apply fails at admission.
    secretsNamespaceLabels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  })]
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
