# cloudflared: the in-cluster connector for the tunnel. Outbound-only (udp
# 7844 QUIC to the Cloudflare edge, FW-015); proxies inbound requests to the
# external Traefik instance over its ClusterIP service. Two replicas, one per
# node, so a node drain never drops the public edge.

resource "kubernetes_namespace" "cloudflared" {
  metadata {
    name = "cloudflared" # baseline PSA; cloudflared runs non-root
  }
}

resource "kubernetes_secret" "tunnel_token" {
  metadata {
    name      = "cloudflared-token"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
  }
  data = {
    TUNNEL_TOKEN = data.cloudflare_zero_trust_tunnel_cloudflared_token.homelab.token
  }
}

resource "kubernetes_deployment" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
    labels    = { app = "cloudflared" }
  }

  spec {
    replicas = var.cloudflared_replicas

    selector {
      match_labels = { app = "cloudflared" }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        # Required anti-affinity + 3 nodes: never surge past the node count.
        max_surge       = "0"
        max_unavailable = "1"
      }
    }

    template {
      metadata {
        labels = { app = "cloudflared" }
        annotations = {
          # Token rotation replaces the Secret, but pods only re-read it on
          # restart -- the checksum change forces the rollout.
          "checksum/tunnel-token" = sha256(data.cloudflare_zero_trust_tunnel_cloudflared_token.homelab.token)
        }
      }

      spec {
        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              topology_key = "kubernetes.io/hostname"
              label_selector {
                match_labels = { app = "cloudflared" }
              }
            }
          }
        }

        container {
          name  = "cloudflared"
          image = var.cloudflared_image
          # QUIC only, deliberately: the http2 fallback uses tcp 7844, which
          # FW-015 and the containment policy both block (fail closed).
          args = ["tunnel", "--no-autoupdate", "--metrics", "0.0.0.0:2000", "--protocol", "quic", "run"]

          env {
            name = "TUNNEL_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.tunnel_token.metadata[0].name
                key  = "TUNNEL_TOKEN"
              }
            }
          }

          # /ready returns 200 iff the connector has an active edge connection.
          liveness_probe {
            http_get {
              path = "/ready"
              port = 2000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = 2000
            }
            period_seconds = 10
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 65532
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }
}

# Containment (wifi_and_isolation.md §4): default-deny around the connector
# pods, enforced by Cilium. No ingress at all -- the tunnel is outbound-only.
# Outbound only to cluster DNS, the Cloudflare edge (never RFC1918), and the
# external Traefik entry point.
resource "kubernetes_network_policy" "containment" {
  metadata {
    name      = "cloudflared-containment"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"] # no ingress blocks = deny all inbound

    egress {
      # Cluster DNS (CoreDNS in kube-system).
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports {
        port     = 53
        protocol = "UDP"
      }
      ports {
        port     = 53
        protocol = "TCP"
      }
    }

    egress {
      # Cloudflare edge: QUIC 7844 plus tcp 443 (tunnel API/bootstrap).
      # Public internet only -- RFC1918 stays unreachable from these pods.
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
        }
      }
      ports {
        port     = 7844
        protocol = "UDP"
      }
      ports {
        port     = 443
        protocol = "TCP"
      }
    }

    egress {
      # Origin: the external Traefik pods. Cilium's kube-proxy replacement
      # translates the ClusterIP before egress policy is evaluated, so this
      # must match the pod-side port 8443, not the service port 443.
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.traefik_external_namespace }
        }
      }
      ports {
        port     = 8443
        protocol = "TCP"
      }
    }
  }
}
