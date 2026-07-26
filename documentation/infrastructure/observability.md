# Observability

Single-pane observability for the cluster and its applications: metrics, logs
and traces in one Grafana, alerts to Discord. Deployed via GitOps
(`programming/gitops_apps.md`); all charts live under `kubernetes/apps/`.

## Components

| App | Namespace | Role |
|---|---|---|
| `kube-prometheus-stack` | `monitoring` | Prometheus (metrics, 15d/22GB retention, 25Gi Longhorn), Alertmanager (1Gi), Grafana (5Gi, the single UI), kube-state-metrics, default dashboards and rules |
| `loki` | `monitoring` | Log store, single-binary mode, filesystem on 25Gi Longhorn, 14d retention |
| `tempo` | `monitoring` | Trace store, monolithic mode, 25Gi Longhorn, 7d retention |
| `node-exporter` | `monitoring-system` | Host metrics DaemonSet (standalone — see PSA split in `gitops_apps.md`) |
| `alloy-logs` | `monitoring-system` | DaemonSet tailing `/var/log/pods` on every node into Loki |
| `alloy-gateway` | `monitoring` | OTLP gateway ×2 for application telemetry |
| `kyverno-monitoring` | `kyverno` | One ServiceMonitor over all four Kyverno controllers' `*-metrics` Services, plus the alerts below. Its own app, not part of `kyverno` — that one is wave `-2`, before the `monitoring.coreos.com` CRDs exist (`programming/gitops_apps.md`). The Grafana dashboard for these metrics stays in the `kyverno` app (`grafana.enabled`): a ConfigMap, not a CRD-backed kind |
| `infra-monitoring` | `monitoring` | ServiceMonitors and alerts for the six platform components that cannot carry their own — see below |

Grafana is published at `grafana.<domain>` behind `traefik-internal`
(LAN-only, wildcard cert — `programming/publishing_apps.md`). No DNS record:
the internal zone's wildcard already resolves there. Admin login:
Key Vault `monitoring--grafana-admin-password`, synced in by ESO
(`programming/gitops_apps.md`). Datasources (Prometheus, Loki, Tempo) are
provisioned; custom dashboards load via the sidecar, which watches every
namespace for ConfigMaps labelled `grafana_dashboard: "1"` — the same
any-namespace discovery the ServiceMonitor/PrometheusRule selectors use. An
app ships its own dashboard by rendering one; the Kyverno dashboard comes
from the kyverno chart itself (`grafana.enabled`, in the wave `-2` `kyverno`
app rather than `kyverno-monitoring` — a ConfigMap needs no CRD).

## Application telemetry (OTLP)

Applications send OTLP to the in-cluster gateway — no Ingress, in-cluster
only:

- gRPC: `http://alloy-gateway.monitoring.svc.cluster.local:4317`
- HTTP: `http://alloy-gateway.monitoring.svc.cluster.local:4318`

The gateway routes: traces → Tempo (OTLP), logs → Loki (native OTLP ingest),
metrics → Prometheus remote-write (`enableRemoteWriteReceiver`). Future
consideration: migrate the metrics path from remote-write to native Prometheus
OTLP ingestion (`/api/v1/otlp`) — OTLP is the direction the OpenTelemetry
ecosystem is converging on.

## Alerting

Alertmanager delivers to Discord via the native `discord_configs` receiver.
The webhook URL is Key Vault `monitoring--discord-webhook-url`, synced by ESO
into the `alertmanager-discord` Secret and referenced with `webhook_url_file` —
it never appears in git. Receivers: `discord` (default route) and `deadletter`
(no-op; holds `Watchdog` and any alert routed away temporarily while
troubleshooting).

`kubernetes/apps/monitoring/kyverno-monitoring/templates/alerts.yaml` adds two rules, both
on the default route: `KyvernoAdmissionControllerDown` (no ready admission-controller
pod for 5m — every enforcing ClusterPolicy pins
`spec.webhookConfiguration.failurePolicy: Fail`, so this means all cluster
admission is blocked) and `KyvernoHighPolicyDenyRate` (sustained spike in
admission denies — either an attack/misconfiguration being caught, or a
`kyverno-policies` rule wrongly blocking a legitimate deploy).

Both expressions are guarded. `KyvernoAdmissionControllerDown` is
`== 0 or absent(...)`: `sum()` over an empty vector yields no samples, so a
bare `== 0` goes silent if the pods or kube-state-metrics disappear — the
outage it exists to catch. `KyvernoHighPolicyDenyRate` filters
`resource_request_operation != ""` to count admission results only;
`kyverno_policy_results_total` is also incremented by background scans, where
`workload-best-practices`' two `Audit` rules fail for every third-party
container running without a probe or without resource requests on each cycle.

`kubernetes/apps/database/postgres/templates/alerts.yaml` adds seven PostgreSQL
rules on the same route. The same app also renders CloudNativePG's official
dashboard, as a URL stub that kube-prometheus-stack's Grafana sidecar resolves
at runtime rather than a vendored JSON ConfigMap (`databases.md`).

Any app may ship a dashboard the same way: a `grafana_dashboard`-labelled
ConfigMap in its own namespace, picking its Grafana folder with a
`grafana_folder` annotation. That annotation is honoured because
kube-prometheus-stack sets both `sidecar.dashboards.folderAnnotation` and
`provider.foldersFromFilesStructure` — one without the other silently drops
every dashboard at the root.

`PostgresNoStreamingReplica` is the one specific to how that cluster is
configured: `synchronous.dataDurability: required` means a commit needs a
standby to confirm it, so zero connected streaming replicas is a write stall
rather than degraded replication. `PostgresInstanceNotReady` deliberately reads
kube-state-metrics instead of a `cnpg_` metric — an instance whose pod will not
start exports no PostgreSQL metrics at all, so the thing that notices cannot
come from the instance. Both carry the same `absent()` guard as the Kyverno
rules above, for the same reason. Volume fullness is left to
kube-prometheus-stack's default `KubePersistentVolumeFillingUp`
(`databases.md`).

## Platform components (`infra-monitoring`)

Cilium, cert-manager, Longhorn, Traefik and ArgoCD are installed by Terraform
(layers 40 and 60), and External Secrets is a GitOps app at wave `-2`. In every
one of those cases the `monitoring.coreos.com` CRDs do not exist at the moment
the component installs, so its chart's own `serviceMonitor` flag cannot be
used: at layer 40 it fails the apply, and at wave `-2` it stalls the root app
before the wave that installs the CRD. What each chart *can* do at install time
is expose the metrics endpoint and its Service, which is what
`values/cilium.yaml`, the ESO app's `metrics.service.enabled` and Traefik's
`metrics.prometheus.service.enabled` do.

The ServiceMonitors that scrape them live in `infra-monitoring` at wave `1`,
the same split `kyverno-monitoring` uses and for the same reason. Selectors are
on labels the charts set unconditionally, never on
`app.kubernetes.io/instance` — that one is also ArgoCD's tracking label, so it
is owned by two things at once.

Alerts in the same app, grouped by what they catch:

- **cert-manager** — `CertManagerCertExpiringSoon` is the one that matters
  most. A single wildcard certificate fronts every published hostname on both
  Traefik instances and renews unattended over ACME DNS-01; before this rule
  existed a renewal that stopped working produced no signal at all until the
  certificate expired and the whole public edge broke TLS. It fires at 21 days
  remaining, nine days after cert-manager should have renewed, so it means
  renewal is failing rather than pending.
- **Longhorn** — volume faulted (no usable replica), volume degraded for 30m
  (not rebuilding), node not ready.
- **ArgoCD** — an app out of sync or unhealthy for 30m. With automated sync and
  self-heal on, 30m means syncing is failing, commonly a project permission or
  an admission denial.
- **External Secrets** — an `ExternalSecret` not Ready. The existing Secret
  keeps its last-synced value, so nothing breaks immediately; the symptom is a
  credential going stale, which several weeks later becomes the cert-manager
  alert above.
- **Traefik and Cilium** — read from kube-state-metrics rather than from the
  component, because one that is not running exports nothing.

Every expression that could lose its series carries an `absent()` arm, for the
same reason the Kyverno and PostgreSQL rules do.

## Talos scrape disables

Disabled in kube-prometheus-stack, together with their default rules:

- `kubeProxy` — kube-proxy does not exist; Cilium replaces it
  (40-kube-networking).
- `kubeControllerManager`, `kubeScheduler`, `kubeEtcd` — bind metrics to
  localhost on Talos. Enabling them is a 30-talos machine-config change, not a
  chart change.

Prometheus discovers ServiceMonitors/PodMonitors/Rules across all namespaces
(`*SelectorNilUsesHelmValues: false`) — required for the standalone
node-exporter and Alloy.
