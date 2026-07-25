# GitOps bootstrap. ArgoCD deploys everything under kubernetes/apps from git
# (documentation/programming/gitops_apps.md); in-cluster secrets come from
# Azure Key Vault through External Secrets Operator. Terraform's role is the
# irreducible floor that cannot itself come from git:
#   1. the external-secrets namespace,
#   2. the Service Principal credential ESO authenticates to Key Vault with
#      (a chicken-and-egg: ESO cannot read its own credential from the vault),
#   3. the root Application pointer, injecting the domain and tenant so neither
#      lands in git.
# Namespaces, the ClusterSecretStore and every app secret are git/ESO-managed.

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
    # Baseline PSA is fine (ESO is non-root), but the label is set here rather
    # than via the app registry's namespaceLabels: this namespace is
    # Terraform-owned, and kubernetes_namespace replaces the whole labels map,
    # so an ArgoCD-managed label would be stripped on every apply and healed
    # back. kyverno-policies' require-namespace-psa-label needs it present.
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

# Consumed by the azure-kv ClusterSecretStore
# (kubernetes/apps/security/cluster-secrets). The only namespace this credential exists
# in -- a namespaced SecretStore elsewhere would have no credential to use, and
# Kyverno forbids a second ClusterSecretStore, so no namespace can reach Key
# Vault by any other path.
resource "kubernetes_secret" "azure_kv_creds" {
  metadata {
    name      = "azure-kv-creds"
    namespace = kubernetes_namespace.external_secrets.metadata[0].name
  }

  data = {
    "client-id"     = data.azurerm_key_vault_secret.azure_kv_sp_client_id.value
    "client-secret" = data.azurerm_key_vault_secret.azure_kv_sp_client_secret.value
  }
}

locals {
  # Shared with scripts/check_cluster_policy.py, which refuses a PR whose
  # rendered manifests these rules would reject at sync time. One file, two
  # readers -- a copy in the script would be a copy that drifts, and a drifted
  # copy is green CI over a cluster that refuses the apply.
  appprojects = yamldecode(file("${path.module}/appprojects.yaml"))

  registry_project_spec = {
    for name, proj in local.appprojects.projects : name => {
      description  = proj.description
      sourceRepos  = [var.gitops_repo_url]
      destinations = proj.destinations
      clusterResourceWhitelist = concat(
        local.appprojects.sharedClusterResources,
        proj.extraClusterResources,
      )
    }
  }
}

# AppProjects. Terraform owns these rather than the bootstrap chart for the
# same reason it owns the ESO credential: an AppProject is an authorization
# boundary, and a boundary the thing it constrains can rewrite is decorative.
# Rendered from git, the root Application would be able to widen its own
# permissions in the same sync that used them.
#
# Three projects, split by blast radius:
#   bootstrap           -- the root app. Renders Applications into argocd and
#                          nothing else, so it needs no cluster-scoped
#                          permission at all. Defined here rather than in
#                          appprojects.yaml: its one destination is the argocd
#                          namespace resource, not a literal.
#   homelab             -- the registry default.
#   homelab-kube-system -- the same, plus the kube-system destination, for the
#                          apps whose upstream chart writes there.
#
# The rules for the latter two are appprojects.yaml (see the local above).
#
# ArgoCD validates every rendered object individually, not just the
# Application's destination: controller/sync.go checks each object's own
# metadata.namespace against the project's destinations and its group/kind
# against clusterResourceWhitelist. A chart writing outside its destination
# namespace therefore needs that namespace permitted.
resource "kubectl_manifest" "project_bootstrap" {
  depends_on = [helm_release.argocd]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "bootstrap"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      description = "Root app-of-apps only: renders Applications, nothing else."
      sourceRepos = [var.gitops_repo_url]
      destinations = [{
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace.argocd.metadata[0].name
      }]
      # The bootstrap chart renders exactly one kind. Anything else appearing
      # under kubernetes/bootstrap is a mistake, and this refuses it.
      clusterResourceWhitelist = []
      namespaceResourceWhitelist = [{
        group = "argoproj.io"
        kind  = "Application"
      }]
    }
  })
}

resource "kubectl_manifest" "project_homelab" {
  depends_on = [helm_release.argocd]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "homelab"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = local.registry_project_spec["homelab"]
  })
}

# Separate resource rather than for_each over the map: the address
# kubectl_manifest.project_homelab is already in state, and moving it would
# destroy and recreate a live authorization object while the apps it governs
# are running.
resource "kubectl_manifest" "project_homelab_kube_system" {
  depends_on = [helm_release.argocd]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "homelab-kube-system"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = local.registry_project_spec["homelab-kube-system"]
  })
}

# Root app-of-apps: points ArgoCD at kubernetes/bootstrap, which renders one
# Application per registry entry. kubectl_manifest (not kubernetes_manifest)
# because the Application CRD only exists after helm_release.argocd --
# kubernetes_manifest needs the CRD at plan time and breaks fresh rebuilds
# (same reasoning as 40-kube-networking).
resource "kubectl_manifest" "root_app" {
  # Every project, not just bootstrap: an Application naming a project that
  # does not exist yet goes to an error state, and the root app creates its
  # children immediately.
  depends_on = [
    helm_release.argocd,
    kubectl_manifest.project_bootstrap,
    kubectl_manifest.project_homelab,
    kubectl_manifest.project_homelab_kube_system,
  ]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      # Not "default": that project permits everything, so the root app could
      # deploy any kind anywhere. It only ever renders Applications.
      project = "bootstrap"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_revision
        path           = "kubernetes/bootstrap"
        helm = {
          parameters = [
            # The public domain is a Key Vault secret (PII rule); the tenant id
            # is likewise injected so neither appears in git.
            { name = "domain", value = local.domain },
            { name = "tenantId", value = data.azurerm_client_config.current.tenant_id },
            { name = "repoURL", value = var.gitops_repo_url },
            { name = "revision", value = var.gitops_revision },
            # Vault URL derived from the same Key Vault Terraform reads --
            # single source of truth instead of a copy in git.
            { name = "vaultUrl", value = trimsuffix(data.azurerm_key_vault.this.vault_uri, "/") },
            # From 10-network remote state: gates apps whose registry entry
            # sets onlyEdgeMode (cloudflared renders only in tunnel mode).
            # Flipping edge_mode: apply 10-network, 50-cloudflare, then here.
            { name = "edgeMode", value = data.terraform_remote_state.network.outputs.edge_mode },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })
}
