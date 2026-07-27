# Upgrades

How each layer of the platform is moved forward. Everything here is a
deliberate act with a verification step; nothing upgrades itself.

`disaster_recovery.md` is the other half of this document — that one is for
when something is already broken.

## Before any of it

| Need | Why |
|---|---|
| `az login` | Every layer's backend and secret lookups |
| A machine on **VLAN 10** | FW-003/FW-003-talos/PVE-FW-002 permit admin access from that VLAN only |
| `talosctl` matching the *current* Talos minor | The client is forward-compatible one minor, not backwards |
| A green `cluster-policy-check` | Chart bumps are validated against the values this repo applies, not chart defaults |

---

## Talos

**A Talos version bump is not a Terraform apply.** `talos_version` in
`terraform/20-proxmox/terraform.tfvars` builds the Image Factory schematic and
the boot image; the running OS is upgraded in place by `talosctl`, against the
same factory installer 30-talos pins into `machine.install.image`.

The VM resource ignores changes to `disk[0].file_id` for exactly this reason
(`terraform/20-proxmox/vms.tf`). Without that, bumping the version renames the
downloaded image, the provider resolves the new id by replacing the disk, and
three nodes lose etcd and every Longhorn replica in parallel — for what is
meant to be a rolling upgrade.

### Procedure

1. Bump `talos_version` in `terraform/20-proxmox/terraform.tfvars`. Check
   whether the new release changes its default Kubernetes version; if it does,
   `kubernetes_version` in `terraform/30-talos/terraform.tfvars` moves in the
   same change or stays pinned deliberately.

2. Apply 20-proxmox. It downloads the new image and rebuilds the schematic.
   **The plan must show no VM replacement.** If it does, the `ignore_changes`
   block is gone — stop.

   ```bash
   cd terraform/20-proxmox && terraform apply
   ```

3. Apply 30-talos, which writes the new `machine.install.image` into each
   node's config. This does not upgrade anything; it decides what the next
   upgrade installs.

   ```bash
   cd terraform/30-talos && terraform apply
   ```

4. Read the installer image out of state, then upgrade **one node at a time**:

   ```bash
   terraform -chdir=terraform/20-proxmox output -raw installer_image
   ```

   ```bash
   talosctl --talosconfig talosconfig --nodes 10.1.11.11 upgrade --image <installer_image> --wait
   ```

   The node reboots. Before touching the next one, confirm the cluster is whole
   again:

   ```bash
   talosctl --talosconfig talosconfig --nodes 10.1.11.11 health --server=false
   ```

   ```bash
   kubectl get nodes
   ```

   Then repeat for `10.1.11.12` and `10.1.11.13`.

**All three nodes are control plane.** Two simultaneous reboots lose etcd
quorum, and the cluster does not come back on its own. There is no automation
here on purpose: the serialisation is the safety property.

PostgreSQL is the workload that notices. Required anti-affinity means the
drained node's instance goes `Pending` until the node returns, and with
`synchronous.dataDurability: required` a second node down during the window
stalls writes (`databases.md`). One node at a time, healthy between each.

### Machine-config changes

The same constraint applies to any 30-talos change that reboots — sysctls,
kernel modules, install disk. `talos_machine_configuration_apply` is a
`for_each` and Terraform cannot serialise one, so drive it per node:

```bash
cd terraform/30-talos && terraform apply -target='talos_machine_configuration_apply.node["k8s-node-1"]'
```

Wait for the node to rejoin, repeat for each, then run a bare `terraform apply`
to settle the rest of the layer. Layer 30's pre-CNI `talos_cluster_health` gate
makes a full-blast apply fail if Talos, the Kubernetes API, or etcd has not come
back; it deliberately leaves Kubernetes node readiness to the post-Cilium gate
in 40-kube-networking.

`longhorn_v2_data_engine` is one of these: it reserves 1024 hugepages per node
and reboots. Flipping it means 30-talos node-by-node, then 40-kube-networking,
which reads the flag out of 30-talos's state so the Longhorn setting and the
node prerequisites cannot disagree.

---

## Kubernetes

Pinned as `kubernetes_version` in `terraform/30-talos/terraform.tfvars`. It is
pinned rather than left to the provider default because an unpinned value moves
whenever the provider build does, with nothing in the diff naming it.

Talos v1.13 supports the six minor versions back from its own default. Upgrade
one minor at a time.

```bash
talosctl --talosconfig talosconfig --nodes 10.1.11.11 upgrade-k8s --to 1.36.2
```

Run it **once**, against one node — `upgrade-k8s` orchestrates the whole
cluster itself, unlike `upgrade`. Then set `kubernetes_version` in the tfvars to
the same value and apply 30-talos, so the config on disk matches what is
running and the next machine-config apply does not revert it.

Check the deprecated-API surface first. Nothing in this repo currently uses a
deprecated API version, but chart CRDs move independently:

```bash
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
```

---

## Helm charts

Two populations, upgraded differently.

### Terraform-managed (Cilium, cert-manager, Longhorn, Traefik, ArgoCD)

Renovate opens the PR against the `# renovate:`-annotated pin in that layer's
`terraform.tfvars`. CI renders the chart at the new version **with the values
files the layer applies** (`terraform/<layer>/values/<chart>.yaml`), so a bump
that invalidates a key fails on the PR.

That check exists because both failure modes had already happened: the Traefik
chart moved `ports.web.redirections` under `http` and its schema refuses the
old key outright, and the argo-cd chart never had a `server.insecure` key at
the top level and silently discarded it. Neither was visible while CI rendered
chart defaults.

After merge:

```bash
cd terraform/40-kube-networking && terraform plan
```

Read the plan. A `helm_release` shows as an in-place update; anything showing
replacement of a namespace or a `kubectl_manifest` is a different change than
you think you are making.

**Traefik CRDs upgrade separately.** Helm never upgrades a chart's own `crds/`
directory, which is why the CRDs come from the `traefik-crds` chart with its
own pin (`traefik_crds_chart_version`). Bump it alongside the traefik chart;
its number lags, because it is republished only when the CRDs change.

### GitOps-managed (everything under `kubernetes/apps`)

Renovate bumps the dependency in the app's `Chart.yaml`, CI renders it, ArgoCD
applies it on merge. ArgoCD renders with `--include-crds`, so CRDs are ordinary
managed resources and do upgrade — the Traefik problem above does not apply
here.

Two things to re-check on any major bump, both enforced by CI but worth
understanding before the PR is opened:

- **Image registries.** `kyverno-policies` is `Enforce` and fail-closed, so a
  new registry is a rejected pod, not a flagged one — and for a running
  workload the rejection lands on its next restart, not at merge.
- **Rendered object size.** Anything past 262144 bytes needs
  `ServerSideApply=true` on its registry entry. `helm template <app>
  --include-crds` reproduces the measurement.

---

## PostgreSQL

A **minor** version bump is `image.tag` in
`kubernetes/apps/database/postgres/values.yaml`: rolling restart, standbys
first, switchover at the end (`primaryUpdateMethod: switchover`).

A **major** version bump is not. The operator runs an offline `pg_upgrade` Job;
the cluster is unavailable for its duration, and reverting means restoring from
a backup. Read `databases.md` on what backups exist before starting one.

---

## Technitium

The official installer takes no version parameter and always fetches the
current release, so the version is not pinned at install time. `ansible/`
asserts against it afterwards: set `technitium_version` in
`roles/technitium/defaults/main.yml` and a run fails when the installed server
does not match.

Upgrading is the installer again, one server at a time — `10.0.10.5` first, so
the primary keeps answering while the secondary is down, and a secondary that
comes back wrong is a zone transfer away from correct rather than a rebuild.
The playbook skips the installer when `dns.service` already exists, so an
upgrade is `systemctl stop dns` and a manual installer run on that host, then a
normal playbook run to reassert settings and zones.

Independent of the ordering below: DNS is under the whole stack, and a
Technitium upgrade touches nothing the cluster versions care about. Do it in its
own window (`core_infra.md`).

---

## Azure DevOps agents

Four pins, all in `roles/azdo_agent/defaults/main.yml`, all kept fresh by a
Renovate custom manager: the agent itself, `kubectl`, `helm` and `yq`. An
upgrade is a version edit and a normal playbook run — the role probes each
tool, installs only on a mismatch, and asserts afterwards.

The agent is the one that will surprise you. **Azure DevOps upgrades an agent
in place** when the server requires a newer one, so the version on disk drifts
upward on its own. The assertion after install is what turns that into a
visible failure instead of silent drift, and the fix is to repin to what the
server installed, never to roll back — a downgraded agent is upgraded again on
its next job.

`azdo_agent_kubectl_version` is not independent: it tracks the cluster's
control plane, one minor of skew either way, so it moves with step 3 below and
in the same window. `azdo_agent_helm_version` tracks the pin in
`.github/workflows/cluster-policy-check.yml`, so an agent renders a chart with
the helm CI validated it with.

Otherwise the agents sit outside the ordering below entirely: nothing in the
stack depends on them, and an agent that is down costs pipelines and nothing
else (`azdo_agents.md`).

---

## UniFi and Proxmox

Neither is Terraform-managed.

- **UniFi firmware**: applied from the controller UI during a maintenance
  window (`../networking/physical_network.md`, step 10). Take a controller
  backup first. A UniFi Network major version can change the firewall data
  model that `ubiquiti-community/unifi` writes — run `terraform plan` on
  10-network afterwards and read it before applying anything else.
- **Proxmox VE**: host package upgrades, one host at a time, migrating or
  accepting the downtime of the guests on it. A pve host reboot takes one k8s
  node and one core-infra LXC with it, so the same one-at-a-time rule as the
  Talos section applies, and for the same reason.

---

## Order

When several are due at once:

1. Proxmox hosts (below everything)
2. Talos
3. Kubernetes
4. Terraform-managed charts
5. GitOps charts
6. PostgreSQL

Each step verified before the next. The failure this ordering avoids is
upgrading a chart onto a Kubernetes version it has not been tested against and
then being unable to tell which of the two changes broke it.
