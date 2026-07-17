# GitOps Apps

In-cluster applications are deployed by ArgoCD from this repository. Terraform's
role ends at the ArgoCD install and the bootstrap pointer (60-argo-cd
`gitops.tf`); everything under `kubernetes/apps` is owned by ArgoCD.

## Layout

```
kubernetes/
├── bootstrap/            # root app-of-apps chart
│   ├── Chart.yaml
│   ├── values.yaml       # the app registry
│   └── templates/applications.yaml
└── apps/
    └── <name>/           # one directory per app
        ├── Chart.yaml    # umbrella: pins the upstream chart as a dependency
        ├── values.yaml   # all configuration, under the dependency's name key
        └── templates/    # optional extra resources (Ingress, etc.)
```

Each app is an umbrella Helm chart: `Chart.yaml` declares the upstream chart as
a pinned dependency (exact version — never latest, bump on purpose, same rule
as `argocd_chart_version`; Renovate proposes bumps), and `values.yaml` nests
the upstream values under the dependency name. ArgoCD resolves the dependency
at render time; no `Chart.lock` is committed. An app with no upstream chart
(`cloudflared/`) is the same shape minus the dependency — plain `templates/`.

Adding an app: create `kubernetes/apps/<name>/`, add one entry to the registry
in `kubernetes/bootstrap/values.yaml`, push. The registry entry sets the
destination namespace, sync wave, which injected parameters the app receives
(`needsDomain`, `needsTenant`, `needsVaultUrl`), an optional edge-mode gate
(`onlyEdgeMode`), and any extra sync options. Future candidates follow the
same pattern (for example `authentik/`, `harbor/`, `open-webui/`, or
migrations of the Terraform-managed `cert-manager`/`longhorn`).

## Edge-mode gating

`edge_mode` is owned by `terraform/10-network` and forwarded by the root
Application as the `edgeMode` parameter. A registry entry with
`onlyEdgeMode: tunnel` renders only when the modes match — `cloudflared` (the
tunnel connector) exists in tunnel mode and is pruned by ArgoCD in dnat mode.
Flipping the mode is a three-layer apply: 10-network, 50-cloudflare,
60-argo-cd (re-renders the parameter).

## Bootstrap

Terraform (60-argo-cd `gitops.tf`) creates a single root Application pointing
at `kubernetes/bootstrap`. The bootstrap chart renders one Application per
registry entry. ArgoCD pulls the repository anonymously (public repo, no
credential). The tracked branch is `gitops_revision` in
`terraform/60-argo-cd/terraform.tfvars` and is forwarded to every child.

## Domain injection

The public domain is a Key Vault secret and never appears in git. The root
Application injects it as the Helm parameter `domain` (read by Terraform from
Key Vault); the bootstrap chart forwards it as `global.domain` to each app with
`needsDomain: true`. App templates reference `{{ .Values.global.domain }}` —
committed values files carry an empty string. The Azure tenant (`needsTenant` →
`global.tenantId`) and the Key Vault URL (`needsVaultUrl` → `vaultUrl`, derived
from the vault Terraform reads — one source of truth) are injected the same
way.

## Secrets

In-cluster secrets come from Azure Key Vault through External Secrets Operator
(`kubernetes/apps/external-secrets`), never from Terraform-created Secrets and
never committed. One `ClusterSecretStore` named `azure-kv`
(`kubernetes/apps/cluster-secrets`) is the only store in the cluster; it
authenticates with the `azure-kv-creds` Service Principal credential that
Terraform plants in the `external-secrets` namespace (60-argo-cd `gitops.tf`) —
the single bootstrap secret ESO cannot fetch for itself. A vault value may
itself be Terraform-written when it originates in a Terraform resource
(`cloudflared--tunnel-token`, 50-cloudflare) — the in-cluster path is still
ESO.

Key Vault keys are namespaced: `<namespace>--<name>`, double dash. A secret an
app in `monitoring` needs is `monitoring--<name>`. The app carries its own
`ExternalSecret` referencing that key and the `azure-kv` store; ESO syncs it
into a native Secret in the app's namespace.

Isolation is enforced by Kyverno (`kubernetes/apps/cluster-secrets`), because
Azure RBAC cannot scope a single vault by key prefix:

- every `ExternalSecret` `remoteRef.key` must start with `<its namespace>--`
  (double dash, so `monitoring` cannot reach `monitoring-system--*`);
- `dataFrom` is forbidden (it would dodge the per-key check);
- only the `azure-kv` `ClusterSecretStore` may exist, and namespaced
  `SecretStore`s are forbidden — so no namespace can introduce an alternate
  path to the vault.

Adding a secret is therefore a Key Vault entry plus an `ExternalSecret` in the
app — no Terraform, unless it is a new bootstrap-level credential.

## Namespaces and PSA

ArgoCD creates each namespace, owned by exactly one app (`createNamespace: true`
in the registry, `CreateNamespace=true` syncOption); other apps deploying into
it set `false`. Pod Security Admission labels are applied through the owning
app's `managedNamespaceMetadata`, so they exist before the first pod:

- `monitoring` (owned by `kube-prometheus-stack`) — enforce `baseline`. No
  workload here may request host access.
- `monitoring-system` (owned by `node-exporter`) — enforce `privileged`. Node
  agents only (node-exporter, alloy-logs): hostNetwork/hostPID/hostPath. PSA
  enforcement is namespace-wide, hence the split.

The only Terraform-owned namespace is `external-secrets` — it must hold the
bootstrap credential before ArgoCD runs.

## Sync policy

Every child Application: automated sync with `prune: true` and
`selfHeal: true`, plus `PrunePropagationPolicy=foreground` and `PruneLast=true`
(safe deletes for apps owning PVCs and CRDs). Ordering across apps uses
`argocd.argoproj.io/sync-wave` from the registry: the secret machinery installs
first (wave `-2` External Secrets Operator + Kyverno, wave `-1` the store and
policies), then apps from wave `0`. `kube-prometheus-stack` additionally
requires `ServerSideApply=true` — its CRDs exceed the client-side
`last-applied-configuration` annotation size limit.
