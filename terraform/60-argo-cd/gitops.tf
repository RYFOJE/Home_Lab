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

# AppProjects. Terraform owns these rather than the bootstrap chart for the
# same reason it owns the ESO credential: an AppProject is an authorization
# boundary, and a boundary the thing it constrains can rewrite is decorative.
# Rendered from git, the root Application would be able to widen its own
# permissions in the same sync that used them.
#
# Two projects, split by blast radius:
#   bootstrap -- the root app. Renders Applications into argocd and nothing
#                else, so it needs no cluster-scoped permission at all.
#   homelab   -- every app in the registry. Namespaces stay open (see below);
#                the cluster-scoped surface is a closed list.
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
    spec = {
      description = "Every app in the kubernetes/bootstrap registry."
      sourceRepos = [var.gitops_repo_url]
      # Namespaces stay wildcarded on purpose. Enumerating the six current
      # namespaces would mean a Terraform apply every time an app lands in a
      # new one, which breaks the "adding an app = one directory + one
      # registry entry" property this repo is built around
      # (documentation/programming/gitops_apps.md). The real blast radius is
      # cluster-scoped resources, and that list below is closed. The three
      # API-server namespaces are denied outright -- Kyverno's default
      # resourceFilters already skip them, so a write there would land
      # unpoliced.
      destinations = [
        { server = "https://kubernetes.default.svc", namespace = "*" },
        { server = "https://kubernetes.default.svc", namespace = "!kube-system" },
        { server = "https://kubernetes.default.svc", namespace = "!kube-public" },
        { server = "https://kubernetes.default.svc", namespace = "!kube-node-lease" },
      ]
      # The closed set of cluster-scoped kinds the registry apps render.
      # Derived by rendering each one with `helm template --include-crds` and
      # reading off the kinds whose objects have no namespace; re-derive the
      # same way on a chart bump. Deliberately no counts recorded here -- they
      # would be wrong after the first bump, and the list is the thing that
      # has to be right. A kind missing from it fails that app's sync with a
      # project-permission error rather than passing silently.
      clusterResourceWhitelist = [
        # ArgoCD manages the Namespace object itself wherever a registry entry
        # sets createNamespace + namespaceLabels; omitting this breaks every
        # one of them.
        { group = "", kind = "Namespace" },
        { group = "apiextensions.k8s.io", kind = "CustomResourceDefinition" },
        { group = "rbac.authorization.k8s.io", kind = "ClusterRole" },
        { group = "rbac.authorization.k8s.io", kind = "ClusterRoleBinding" },
        { group = "admissionregistration.k8s.io", kind = "ValidatingWebhookConfiguration" },
        { group = "admissionregistration.k8s.io", kind = "MutatingWebhookConfiguration" },
        # The postgres app ships its own node-local class rather than using the
        # default `longhorn` one (documentation/infrastructure/databases.md).
        { group = "storage.k8s.io", kind = "StorageClass" },
        # Pairs with the Kyverno rule forbidding a second store: that blocks a
        # store created by any means, this blocks the GitOps path to one.
        { group = "external-secrets.io", kind = "ClusterSecretStore" },
        { group = "kyverno.io", kind = "ClusterPolicy" },
        { group = "policies.kyverno.io", kind = "ValidatingPolicy" },
      ]
    }
  })
}

# Root app-of-apps: points ArgoCD at kubernetes/bootstrap, which renders one
# Application per registry entry. kubectl_manifest (not kubernetes_manifest)
# because the Application CRD only exists after helm_release.argocd --
# kubernetes_manifest needs the CRD at plan time and breaks fresh rebuilds
# (same reasoning as 40-kube-networking).
resource "kubectl_manifest" "root_app" {
  # Both projects, not just bootstrap: an Application naming a project that
  # does not exist yet goes to an error state, and the root app creates the
  # homelab-project children immediately.
  depends_on = [
    helm_release.argocd,
    kubectl_manifest.project_bootstrap,
    kubectl_manifest.project_homelab,
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
