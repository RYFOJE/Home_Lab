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

Grafana is published at `grafana.<domain>` behind `traefik-internal`
(LAN-only, wildcard cert — `programming/publishing_apps.md`). The Technitium
record `grafana.<domain>` → 10.1.11.51 is added out of band. Admin login:
Key Vault `monitoring--grafana-admin-password`, synced in by ESO
(`programming/gitops_apps.md`). Datasources (Prometheus, Loki, Tempo) are
provisioned; custom dashboards load via the sidecar (any ConfigMap labelled
`grafana_dashboard`).

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
