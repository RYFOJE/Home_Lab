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
    └── <group>/          # security, monitoring, edge, database, autoscaling -- by function
        └── <name>/       # one directory per app
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

Adding an app: create `kubernetes/apps/<group>/<name>/` (an existing group —
`security`, `monitoring`, `edge`, `database`, `autoscaling` — or a new one), add one entry to
the registry in `kubernetes/bootstrap/values.yaml` with both `name` and `group`
set (the registry template renders `path: kubernetes/apps/{{ .group }}/{{
.name }}`), push. The registry entry also sets the destination namespace,
sync wave, which injected parameters the app receives (`needsDomain`,
`needsTenant`, `needsVaultUrl`), an optional edge-mode gate (`onlyEdgeMode`),
an optional `project`, and any extra sync options. Future candidates follow the
same pattern (for example `authentik/`, `harbor/`, `open-webui/`, or migrations
of the Terraform-managed `cert-manager`/`longhorn`).

## AppProjects

Terraform owns the AppProjects (60-argo-cd `gitops.tf`), not the bootstrap
chart: a boundary the thing it constrains can rewrite is decorative. The root
app would otherwise be able to widen its own permissions in the same sync that
used them.

- `bootstrap` — the root app alone. Renders `Application`s into `argocd` and
  nothing else, so it holds no cluster-scoped permission at all.
- `homelab` — the registry default. Namespaces are wildcarded except
  `kube-system`, `kube-public` and `kube-node-lease`; the cluster-scoped kinds
  are a closed list.
- `homelab-kube-system` — the same, plus the `kube-system` destination and the
  `APIService` kind. Opted into with `project: homelab-kube-system` on a
  registry entry.

Namespaces stay wildcarded in `homelab` on purpose: enumerating them would mean
a Terraform apply every time an app lands in a new one, which breaks the "one
directory plus one registry entry" property. The real blast radius is
cluster-scoped kinds, and that list is closed — a kind missing from it fails
that app's sync with a project-permission error rather than passing silently.
Re-derive it with `helm template <app> --include-crds`, reading off the kinds
whose objects carry no namespace.

ArgoCD validates each rendered object individually, not just the Application's
`spec.destination`: `controller/sync.go` checks every object's own
`metadata.namespace` against the project destinations, and its group/kind
against `clusterResourceWhitelist`. A chart that writes outside its destination
namespace therefore needs that namespace permitted. Two do, and neither offers
a value to stop it — `kube-prometheus-stack` puts the CoreDNS scrape-target
Service beside the pods it scrapes, and `keda` needs
`keda-operator-auth-reader` in `kube-system` so the metrics apiserver can read
`extension-apiserver-authentication` for delegated auth. Both name
`homelab-kube-system`.

That is a second project rather than a `!kube-system` removed from `homelab`
because ArgoCD destinations match on namespace only, never on kind: the
exception cannot be narrowed to those two objects, so it is narrowed to the two
apps instead. `kube-system` stays closed to the rest of the registry, which is
where it matters — Kyverno's default `resourceFilters` drop that namespace, so
a write there lands unpoliced. `APIService` sits in the same project for the
same reason: KEDA registers `v1beta1.external.metrics.k8s.io` (the aggregated
API the HPA controller reads external metrics through, and the reason KEDA
scales anything), and an `APIService` can take over an API group cluster-wide,
so it stays off the project the other apps share.

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
(`kubernetes/apps/security/external-secrets`), never from Terraform-created Secrets and
never committed. One `ClusterSecretStore` named `azure-kv`
(`kubernetes/apps/security/cluster-secrets`) is the only store in the cluster; it
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

Isolation is enforced by Kyverno (`kubernetes/apps/security/cluster-secrets`), because
Azure RBAC cannot scope a single vault by key prefix:

- every `ExternalSecret` `remoteRef.key` must start with `<its namespace>--`
  (double dash, so `monitoring` cannot reach `monitoring-system--*`);
- `dataFrom` is forbidden (it would dodge the per-key check);
- only the `azure-kv` `ClusterSecretStore` may exist, and namespaced
  `SecretStore`s are forbidden — so no namespace can introduce an alternate
  path to the vault.

Adding a secret is therefore a Key Vault entry plus an `ExternalSecret` in the
app — no Terraform, unless it is a new bootstrap-level credential.

## Kyverno

`kubernetes/apps/security/kyverno` is the policy engine (umbrella over the upstream
chart, 2 admission-controller replicas for HA — chart defaults then auto-add
a PodDisruptionBudget and soft anti-affinity). Policies themselves live in two
apps, and its telemetry in a third:

- `kubernetes/apps/security/cluster-secrets` — the `azure-kv` store plus the Key Vault
  isolation policies above. They ship with the store they guard, in one app, so
  the store cannot exist in a sync where its guard is missing.
- `kubernetes/apps/security/kyverno-policies` — general cluster hardening, which guards
  nothing in particular and so is its own app. Four policies in two tiers.
  Enforcing and fail-closed: every `Namespace` must declare a
  `pod-security.kubernetes.io/enforce` label, and its value must be `baseline`
  or `restricted` outside `longhorn-system` and `monitoring-system`; container
  images must come from an allow-listed registry and carry an explicit,
  non-`latest` tag; new bindings to the `cluster-admin` `ClusterRole` are
  denied. Report-only: `workload-best-practices` flags containers with no
  probe, and containers missing CPU/memory requests or a memory limit.
  One `cluster-admin` binding is grandfathered: the Longhorn chart
  (40-kube-networking) creates `longhorn-support-bundle` unconditionally, with
  no flag to disable it, so it is excluded by name. A `ClusterRoleBinding` is
  cluster-scoped, so excluding the `longhorn-system` namespace instead would
  not match; without the exclusion every later `terraform apply` on that layer
  is denied fail-closed. That rule matches the `ClusterRole` *named*
  `cluster-admin` — it is a guard against the lazy grant, not a
  privilege-escalation control, and the same `*/*/*` rules under another name
  are not restricted by it.
- `kubernetes/apps/monitoring/kyverno-monitoring` — one `ServiceMonitor` covering all four
  controllers' `*-metrics` Services, plus the `PrometheusRule`
  (`infrastructure/observability.md`). Split out of the engine app because it
  is the only thing here that needs the `monitoring.coreos.com` CRDs; see the
  wave note under "Sync policy".

### What the image rules require of an app

Every container, init container and ephemeral container in a pod this repo
deploys must resolve to `docker.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`,
`reg.kyverno.io` or `ecr-public.aws.com`, and must carry an explicit tag or
digest. A bare ref such as `cloudflare/cloudflared` counts as `docker.io` — the
rules read Kyverno's `images` context, which normalizes the registry before the
check. An app whose chart pulls from anywhere else needs the registry added to
the allow-list in `kyverno-policies/files/policies.yaml`; the rules are
`Enforce` and fail-closed, so the pods are rejected, not flagged — and for a
workload already running, that rejection lands on its next restart, not at
merge time.

The two non-obvious entries: `reg.kyverno.io` publishes Kyverno's own
controller images as of the 3.x chart, and `ecr-public.aws.com` is where
argo-cd's `redis-ha` and `haproxy` subcharts pull the Docker official images
from — argo-helm moved them off Docker Hub for its rate limits. Both were
found by rendering every chart in the repo and reading the image refs; that
check runs in CI on every PR (`.github/workflows/cluster-policy-check.yml`), so
a chart bump introducing a new registry, a namespace with a missing or
`privileged` PSA label, or a CRD past the annotation-size cap fails at the PR
rather than at wave `-1`/`-2` on the next sync, or on the workload's next
restart.

That workflow makes two passes over one set of rendered manifests.
`scripts/check_cluster_policy.py` renders every GitOps app and every
Terraform-pinned chart, then checks the CRD annotation-size cap and the
registry's `createNamespace`/`namespaceLabels` pairing — neither of which
Kyverno can see, one being about *how* ArgoCD applies a manifest and the other
about a manifest that does not exist yet. `--dump <dir>` writes the rendered
output back out, stamping each app's destination namespace onto namespaced
resources the way ArgoCD does on apply, and the Kyverno CLI then evaluates the
real policy files over that directory. The script's image and PSA checks are a
hand-written mirror of those policies and a mirror can drift, so the CLI pass
is the one with authority; it also catches what a reimplementation
structurally cannot — an unresolved variable, a broken autogen rewrite, a rule
erroring instead of denying. The namespace stamping is what lets the same pass
cover `cluster-secrets` too, since its prefix rule builds the expected Key
Vault prefix from `request.namespace`. `--audit-warn` is required: the ~65
`workload-best-practices` warnings from third-party charts would otherwise
count as failures.

The `kyverno` namespace is excluded from all three image rules: the chart ships
five `helm.sh/hook: test` Pods on `ghcr.io/kyverno/readiness-checker:latest`,
and Kyverno's install/upgrade deadlocking against its own policy is worse than
the gap. Kyverno's default `resourceFilters` already drop that namespace
cluster-wide, so the exclusion is belt-and-braces — stated in the policy rather
than left resting on a ConfigMap default. CI does not mirror it: the check
script skips Helm test hooks across every chart instead (ArgoCD never applies
one), so the images ArgoCD really does apply from that chart stay covered.

Every *enforcing* `ClusterPolicy` in the cluster pins
`spec.webhookConfiguration.failurePolicy: Fail` (already Kyverno's default) —
fail-closed, so a Kyverno outage blocks all admission cluster-wide, which is
what the HA replica count above mitigates. The field is policy-level: rules
within one policy share the failure behaviour, there is no per-rule override.
That is why `workload-best-practices` is a separate policy rather than two more
rules on an existing one — it pins `Ignore`. `failurePolicy` governs what the
API server does when the *webhook is unreachable*, which is unrelated to
`failureAction`; an `Audit` rule denies nothing, so putting it behind a
fail-closed webhook would extend an outage's blast radius to buy nothing.
Kyverno builds one webhook configuration per `failurePolicy`, so the split is
real.

Both rules in that policy are `Audit` rather than `Enforce` because rendering
every chart this repo installs turns up dozens of non-compliant containers in
infrastructure it does not author — Cilium's init containers, cert-manager's
cainjector and `startupapicheck` Job, Longhorn's driver-deployer and UI,
ArgoCD's `redis-ha` subchart, External Secrets, Traefik. Enforcing would deny
that infrastructure on its next rollout over a chart default this repo does not
control. Per-app tightening in an umbrella chart's `values.yaml`, where the
values *are* this repo's, is the path to `Enforce` — not a cluster-wide flip.

Everything is written in JMESPath rather than CEL deliberately. The chart ships
`features.generateValidatingAdmissionPolicy.enabled: true`, and a single-rule
CEL `ClusterPolicy` matching Pods is exactly the shape Kyverno promotes into a
native Kubernetes `ValidatingAdmissionPolicy` — which would move evaluation
into the API server and send `Audit` results to the API-server audit log
instead of the `PolicyReport`s these rules exist to populate. A JMESPath rule
is not eligible for promotion.

`kyverno-policies` runs with `background: true` (unlike `cluster-secrets`,
which stays `background: false`): background scanning only ever produces
`PolicyReport`/`ClusterPolicyReport` entries, never blocks or modifies a
resource, so it's retroactive compliance visibility for free — including for
namespaces/workloads this repo doesn't manage via GitOps (the
Terraform-installed Longhorn/cert-manager/Traefik/ArgoCD layers).
`match`/`exclude` apply to background scanning as well as to admission, so an
excluded namespace (`kyverno`, for the image rules) is absent from the reports
too.

Kyverno's default `resourceFilters` sit in front of every policy in the
cluster and drop `kube-system`, `kube-public`, `kube-node-lease` and `kyverno`
before any rule is evaluated. Cilium and the Talos static control-plane pods
therefore appear in neither admission nor the reports. The PSA rules name all
four API-server-created namespaces in their `exclude` blocks anyway rather than
leaning on those filters for three of them: a filter entry is
`[Kind,Namespace,Name]` and a `Namespace` object is cluster-scoped — its own
`.metadata.namespace` is empty — so it is not obvious that `[*/*,kube-system,*]`
matches `Namespace/kube-system` itself rather than only the things inside it.
Naming them does not depend on the answer.

## Namespaces and PSA

ArgoCD creates each namespace, owned by exactly one app (`createNamespace: true`
in the registry, `CreateNamespace=true` syncOption); other apps deploying into
it set `false`. Pod Security Admission labels are applied through the owning
app's `managedNamespaceMetadata`, so they exist before the first pod:

- `monitoring` (owned by `kube-prometheus-stack`) — enforce `baseline`. No
  workload here may request host access.
- `cnpg-system` (owned by `cloudnative-pg`) and `databases` (owned by
  `postgres`) — enforce `restricted`. The CloudNativePG operator and the
  PostgreSQL instance pods are compliant as shipped
  (`infrastructure/databases.md`), so neither needs the weaker level.
- `monitoring-system` (owned by `node-exporter`) — enforce `privileged`. Node
  agents only (node-exporter, alloy-logs): hostNetwork/hostPID/hostPath. PSA
  enforcement is namespace-wide, hence the split.
- `kyverno` (owned by `kyverno`) — enforce `baseline`.
- `keda` (owned by `keda`) — enforce `restricted`. All three KEDA pods are
  compliant as shipped (`programming/autoscaling.md`).

The only Terraform-owned namespace is `external-secrets` — it must hold the
bootstrap credential before ArgoCD runs. Its PSA label is set on the
`kubernetes_namespace` resource (60-argo-cd `gitops.tf`), not through the
registry: `kubernetes_namespace` replaces the whole labels map, so a label
ArgoCD managed would be stripped on each apply and healed straight back.

`kyverno-policies`' `require-namespace-psa-label` denies any namespace without
an enforce label, on `UPDATE` as well as `CREATE` — an unlabelled namespace is
frozen against all later edits, not merely flagged. A second rule in the same
policy constrains the value: it must be `baseline` or `restricted` everywhere
except `longhorn-system` and `monitoring-system`, the two namespaces above that
genuinely need `privileged`. Requiring only that the label exist would enforce
that the knob is set, not what it is set to — and since PSA is the actual
workload-hardening layer here, that would let any future app opt out of it with
the same one-line registry edit that currently writes `baseline`. Widening the
exception list is then a deliberate act with a diff, which is the point. The
value rule uses equality anchors (`=(labels)`, `=(pod-security…)`) so a
namespace with no label at all fails the presence rule only, instead of landing
in the reports twice under a message about a value it does not have.

Every namespace this repo
creates therefore carries one: from `namespaceLabels` for ArgoCD-owned ones,
and from the `kubernetes_namespace` resource for the Terraform-owned ones
(`external-secrets`, `argocd`, `cert-manager`, `traefik-external`,
`traefik-internal`, `longhorn-system`). One namespace is neither: the Cilium
chart creates `cilium-secrets` itself for CiliumEnvoyConfig TLS material, and
its label comes from the chart's `secretsNamespaceLabels` value
(40-kube-networking `cilium.tf`). A chart that creates a namespace of its own
is the case to watch on any new app — the label has to come from a chart
value, because the registry's `namespaceLabels` only reaches the app's own
destination namespace. The four namespaces the API server creates for itself
(`default`, `kube-system`, `kube-public`, `kube-node-lease`) are excluded —
nothing in this repo can label them.

## Sync policy

Every child Application: automated sync with `prune: true` and
`selfHeal: true`, plus `PrunePropagationPolicy=foreground` and `PruneLast=true`
(safe deletes for apps owning PVCs and CRDs). Ordering across apps uses
`argocd.argoproj.io/sync-wave` from the registry: the secret machinery installs
first (wave `-2` External Secrets Operator + Kyverno, wave `-1` the store,
the Key Vault isolation policies, and general hardening policies), then apps
from wave `0`.

`external-secrets`, `kyverno`, `kube-prometheus-stack`, `cloudnative-pg` and
`keda` additionally require `ServerSideApply=true`: a client-side apply stores
the whole object in the `last-applied-configuration` annotation, which the API
server caps at 262144 bytes, and each ships CRDs past it —
`secretstores`/`clustersecretstores` at ~349 KB, `policies`/`clusterpolicies`
at ~652 KB, six of the `monitoring.coreos.com` CRDs between ~345 and
~482 KB, `clusters`/`poolers.postgresql.cnpg.io` at ~272 KB and ~339 KB, and
`scaledjobs.keda.sh` at ~324 KB.

CRDs are the usual way past that cap, not the only one — a ConfigMap carrying
a vendored dashboard or rule set reaches it just as easily. So the rule is by
object, not by kind: any app rendering *anything* past the limit needs the
option, and `scripts/check_cluster_policy.py` measures every rendered object
rather than only CRDs. The manual check is `helm template <app> --include-crds`
(what ArgoCD renders) measuring each document as JSON. Two of the five are wave
`-2`, so getting this wrong stalls the root app before anything syncs.

A wave is not just a preference: the root app applies wave *n* only once wave
*n-1* is synced and healthy, so an app that cannot apply blocks every later
wave permanently. Nothing before wave `1` may therefore render a
`monitoring.coreos.com` kind — those CRDs arrive with `kube-prometheus-stack`
at wave `0`, and a `ServiceMonitor` at wave `-2` would stall the root app
before the wave that installs its own CRD. That is why Kyverno's
`ServiceMonitor` and `PrometheusRule` are a separate `kyverno-monitoring` app
at wave `1` rather than part of the engine app, and why the upstream chart's
`serviceMonitor.enabled` flags stay off. Nothing catches this on a running
cluster — the CRDs are already there — only on a rebuild.
