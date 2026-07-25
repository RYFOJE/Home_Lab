# Databases

PostgreSQL runs as a CloudNativePG cluster, deployed by ArgoCD from
`kubernetes/apps/database/` (`../programming/gitops_apps.md`). Two apps:

| App | Namespace | Wave | Contents |
|---|---|---|---|
| `cloudnative-pg` | `cnpg-system` | 1 | Operator, CRDs, admission webhooks |
| `postgres` | `databases` | 2 | The `Cluster` resource, its StorageClass, credentials, NetworkPolicy |

The split is the wave: the operator must be synced and healthy before the
`Cluster` resource that needs its CRDs. Wave 1 rather than 0 because the
operator app renders a `PodMonitor`, whose CRD arrives with
kube-prometheus-stack at wave 0 and ordering within a wave is not guaranteed.

Both namespaces enforce PSA `restricted`. The operator's pod and the instance
pods are compliant as shipped — non-root, `RuntimeDefault` seccomp, all
capabilities dropped, no privilege escalation.

## Topology

Three instances, one primary and two standbys, one per Kubernetes node under
required pod anti-affinity on `kubernetes.io/hostname`. The instance count
tracks the node count and is capped at 5; `templates/cluster.yaml` fails the
render outside `[3, maxInstances]`. The cluster cannot reach 5 nodes as
addressed today — the pod CIDR is a `/22`, capping it at 4
(`../networking/allocations.md`) — so the addressing plan is the constraint
that binds first.

One synchronous standby (`synchronous: {method: any, number: 1}`), with
`dataDurability: required`. A commit waits for one of the two standbys, so
losing a single node is zero-RPO and the cluster keeps committing. Losing two
stalls writes rather than falling back to asynchronous replication: the
alternative turns a visible outage into silent data loss.

`enablePDB: true` and required anti-affinity together mean a drained node
leaves its instance `Pending` until the node returns. Two instances on one node
is not a degraded version of this topology — it is a node whose loss takes two
thirds of the cluster, on a disk they would be sharing.

Rollouts update standbys first, then switch the primary role to an
already-updated standby (`primaryUpdateMethod: switchover`) rather than
restarting it in place.

## Storage

Each instance has its own PVC on `longhorn-postgres`, a dedicated StorageClass
shipped with the app: `numberOfReplicas: 1`, `dataLocality: strict-local`,
`WaitForFirstConsumer`, `reclaimPolicy: Retain`.

CloudNativePG is the replication layer. Every instance holds a full copy of the
database, kept current by streaming replication. Putting that on the default
3-replica `longhorn` class would store the data nine times and place a
synchronous cross-node replica write on VLAN 12 in front of every WAL flush —
slower than one node, and no more durable than the Postgres layer already made
it.

The consequence is that a volume cannot follow its pod to another node. Node
failure is handled by the operator promoting a standby; the failed instance is
recovered by deleting its pod *and* its PVC and letting the operator re-clone it
from the primary. That is CloudNativePG's designed failure path, and the
procedure is in `disaster_recovery.md` — the PVC alone will not delete while a
pod still references it, and `Retain` leaves the released `PersistentVolume` and
its Longhorn volume behind to be cleaned up by hand.

50 GiB per instance, single-replica and node-pinned, so 50 GiB of each node's
500 GiB disk (`terraform/20-proxmox` `vm_disk_gb`), alongside the ~81 GiB of
Longhorn replicas the monitoring stack provisions per node. `vm_disk_gb` is the
knob if the data outgrows that.

WAL shares the data volume; `wal_compression` is on.

## Credentials

Two Key Vault secrets, `databases--postgres-superuser-password` and
`databases--postgres-app-password` (`../secrets.md`), synced by External
Secrets Operator into `kubernetes.io/basic-auth` Secrets. Usernames are fixed
in the manifest rather than stored, so a vault edit cannot rename the superuser
out from under the operator.

`superuserSecret` alone does nothing: `enableSuperuserAccess` defaults to false,
and while it is false the operator ignores the secret's content and sets the
`postgres` password to `NULL`. The Cluster sets it to true, which is what makes
superuser access work at all — and what makes the vault the authority for it
rather than a copy that only exists inside the cluster.

The `app` role is declared under `managed.roles`, so the operator reconciles its
password continuously. `bootstrap.initdb.secret` alone applies only at initdb
time, which would make a rotated vault value a no-op inside PostgreSQL.

## Connecting

The operator publishes three Services in `databases`:

| Service | Target |
|---|---|
| `postgres-rw` | current primary — read/write |
| `postgres-ro` | standbys only — read-only |
| `postgres-r` | any instance |

`postgres-rw.databases.svc.cluster.local:5432`, credentials from the
`postgres-app` Secret.

A `CiliumNetworkPolicy` default-denies the namespace. Reachable today only from
within `databases`, from `cnpg-system` (the operator drives each instance
through its instance manager on 8000), from `monitoring` (scrape on 9187), and
from the node itself. A client app is admitted by adding its namespace to
`kubernetes/apps/database/postgres/templates/network-policy.yaml` — the set of
things that can reach the database is a diff, not a default.

The node rule is not decorative. The kubelet's probes reach the instance manager
on 8000 from the host, matching none of the endpoint selectors above, and Cilium
would allow them implicitly under `--allow-localhost=auto` — but only until some
later rule names the `host` entity, at which point the implicit allow is dropped
and every instance fails its probes. The policy names `host` itself so that
behaviour is stated rather than inherited.

Egress is DNS, the other instances, and the Kubernetes API. The API rule is
required for an instance to become ready at all, not only for failover: each
instance runs an instance manager that watches its own `Cluster` resource.

It is a `CiliumNetworkPolicy` rather than the portable `networking.k8s.io/v1`
kind `cloudflared` uses because of that API rule alone. A plain `NetworkPolicy`
can only name the API server as an `ipBlock`, which means copying the
control-plane node IPs out of `terraform/20-proxmox` into an app's values file
where nothing keeps the two in sync — a re-addressed node would silently stop
the database from going ready. `toEntities: kube-apiserver` is an identity
Cilium maintains itself. The `10.1.11.10` VIP is not an alternative for the
`ipBlock` form either: Cilium's kube-proxy replacement resolves the
`kubernetes.default` ClusterIP to its backing endpoints before egress policy is
evaluated, so the rule would have to name the nodes regardless.

All three nodes are combined control-plane, so those endpoints are node
addresses on `6443`. Cilium attaches `reserved:kube-apiserver` to the node
identity in that case, which is both why the entity matches at all and why the
rule grants the nodes rather than an apiserver identity distinct from them —
narrower than an `ipBlock` of the same addresses, not narrow.

Additional databases are `Database` resources against this cluster, not further
`Cluster`s.

## Monitoring

`monitoring.enablePodMonitor` on the cluster and `monitoring.podMonitorEnabled`
on the operator. kube-prometheus-stack discovers PodMonitors in every namespace
(`podMonitorSelectorNilUsesHelmValues: false`), so both are scraped without
further configuration. The operator ships a default query set in the
`cnpg-default-monitoring` ConfigMap — replication, backends, per-database size
and xid age, bgwriter/checkpointer/archiver.

Logs need nothing: `alloy-logs` discovers pods with no namespace filter, so
`databases` already reaches Loki. CloudNativePG logs JSON, so
`{namespace="databases"} | json` gives parsed fields.

`templates/grafana-dashboard.yaml` renders CloudNativePG's official dashboard
(grafana.com/grafana/dashboards/20417-cloudnativepg) into `databases`, owned
by the app it describes rather than by `kube-prometheus-stack`. The ConfigMap
carries no dashboard JSON, only a URL: kube-prometheus-stack's Grafana sidecar
(`grafana-sc-dashboard`, `NAMESPACE=ALL`) watches every namespace for
`grafana_dashboard`-labelled ConfigMaps, and its k8s-sidecar image resolves any
data key ending in `.url` by GETing the value and writing the response body to
disk under the stripped filename. The ConfigMap this app renders is under
300 bytes; the ~250 KB dashboard never enters this repo or crosses the
last-applied-configuration cap, so neither app needs `ServerSideApply=true`
for it.

It lands in a **Databases** folder from the `grafana_folder` annotation. That
takes two settings on the other side, both in
`kubernetes/apps/monitoring/kube-prometheus-stack/values.yaml` and neither
sufficient alone: `sidecar.dashboards.folderAnnotation` tells the sidecar which
annotation to read, and `provider.foldersFromFilesStructure` is what makes
Grafana turn the resulting subdirectory into a folder. Without both, the
annotation is inert and the dashboard lands at the root.

The URL points at `revisions/latest`, not a pinned number — confirmed
byte-identical to revision 4, the current newest, when this was written. The
sidecar re-fetches on Grafana pod restart and on any change to this ConfigMap,
so `latest` means a restart alone picks up a future publish; a pinned number
would need a manual edit to ever move. There is no polling between restarts —
the URL is read once, at the sidecar's initial list-and-sync on startup — and
a grafana.com outage at that moment means the dashboard is simply missing,
not that Grafana fails to start.

This is the only app in the cluster whose rendered output depends on an
outbound fetch at runtime, so it rests on more than the manifest: `monitoring`
carries no NetworkPolicy, FW-015 permits VLAN 11 out on tcp 443, and DNS
resolves through Technitium (FW-001 → FW-013). Losing any of the three costs
the dashboard and nothing else.

`templates/alerts.yaml` is a `PrometheusRule`, auto-discovered
(`ruleSelectorNilUsesHelmValues: false`) and routed to Discord through the
default Alertmanager route. It lives in this app rather than a split-out
`-monitoring` one the way Kyverno's does, because wave 2 is already past the
wave-0 arrival of the `monitoring.coreos.com` CRDs.

The alert that matters most here is `PostgresNoStreamingReplica`. It is a
consequence of `dataDurability: required`: with no standby connected, a commit
has nobody to confirm it and writes stall outright, which no generic PostgreSQL
dashboard treats as an outage. Alongside it: a degraded-replica warning derived
from `instances`, replication lag, instance readiness (from kube-state-metrics,
because an instance that will not start exports no PostgreSQL metrics of its
own), connection saturation against `maxConnections`, long-running
transactions, and xid age.

Volume fullness is deliberately not among them —
kube-prometheus-stack's default `KubePersistentVolumeFillingUp` already covers
these PVCs, and given the disk over-commit above it is the one to watch.

## Upgrades

A minor version bump is a change to `image.tag` in the app's `values.yaml`:
rolling restart, standbys first, switchover at the end.

A major version bump is not. Changing the major in the image tag makes the
operator run an offline `pg_upgrade` Job — the cluster is unavailable for its
duration, and reverting means restoring from a backup.

## Backups

**None are configured.** The cluster is highly available, which is a different
property: three synchronised copies of a `DROP TABLE` are three copies of it.

The PVCs sit on Longhorn, so the existing backup target
(`disaster_recovery.md`) can reach them, but a volume-level backup of a running
database is crash-consistent only — recoverable by WAL replay on start, with no
point-in-time recovery, and restoring one into a live cluster means
bootstrapping a new `Cluster` from the recovered volume rather than a plain
volume restore.

Closing this means CloudNativePG's own backup path: base backups plus WAL
archiving to object storage, and a `ScheduledBackup`. As of the pinned chart
that is the `barman-cloud` CNPG-I plugin rather than the in-core `spec.backup`
stanza, and it needs an object store — an Azure Blob container and its
credential in Key Vault as `databases--postgres-backup`.
