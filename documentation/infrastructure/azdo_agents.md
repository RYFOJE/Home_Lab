# Azure DevOps agents

Two self-hosted Azure Pipelines agents, `azdo-agent-1` (`10.0.10.7`, pve1) and
`azdo-agent-2` (`10.0.10.8`, pve3). They exist because Microsoft-hosted agents cannot reach
`10.1.11.10:6443` — the kube API is LAN-only behind FW-003 — so the deploy half of a pipeline
has to run inside the network. Building stays on the cloud agents; these only deploy.

They are LXCs rather than pods on purpose: they deploy *to* the cluster, so they must not
depend on it being healthy. An agent that cannot run while the cluster is broken cannot be
used to fix it. Placement and addressing in `../networking/allocations.md`.

| | Owner |
|---|---|
| The containers, their addressing, the PVE firewall around them | `terraform/20-proxmox` |
| The agent, kubectl, helm and yq inside them | `ansible/` (this page) |
| The ServiceAccount, its permissions, the `dev` namespace family | `kubernetes/apps/platform/azdo-deployer` |
| Pipeline definitions | Azure DevOps. Nothing in this repo |

## Running it

```bash
cd ansible && ansible-playbook azdo-agent.yml
```

Requires `ansible-core` ≥ 2.15 and `kubectl` on the control node, `az login` (three of its
inputs are Key Vault secrets), a control node on VLAN 10 (LXC-FW-007 permits SSH to `.7`/`.8`
from that VLAN only), and the private half of `lxc_ssh_public_key` from
`terraform/20-proxmox/terraform.tfvars`.

## Ordering

This play runs **last** — step 10 of a full rebuild, after ArgoCD has converged. That is the
opposite of `core-infra.yml`, and for the opposite reason: the `azdo-deployer` ServiceAccount
and its token are GitOps objects at wave 2, so before step 9 there is nothing to read. The
containers themselves are created back at step 2 with the rest of `20-proxmox` and idle until
this runs. Nothing in the stack depends on the agents, so a failure here costs pipelines and
nothing more (`disaster_recovery.md`).

## What the role configures

**Packages.** The agent ships a self-contained .NET runtime but links against system ICU,
Kerberos and LTTng, so those are installed explicitly rather than by the agent's own
`bin/installdependencies.sh`, which shells out to apt itself and reports no useful changed
state. `sudo` is on the list because it is absent from the Debian LXC template and the play
becomes the service user to register. `git`, `jq` and `unzip` are pipeline glue, not agent
dependencies.

**Tooling.** `kubectl`, `helm` and `yq` are pinned static binaries, not apt packages: their
versions track things outside Debian — the cluster's control plane, and the helm CI validates
charts with — and a repository would drift from both. kubectl and helm are verified against
the digest their vendor publishes next to the binary, so the checksum follows the pin instead
of being a second thing to bump; yq has no per-file digest published and gets the version
assertion only.

**The agent.** Unpacked from a pinned tarball, guarded on `config.sh`. Registration is
`config.sh --unattended`, which is *not* idempotent — a second run against a configured agent
errors rather than reconciling — so it is guarded on the `.agent` file it writes on success.
`--replace` means a rebuilt container reclaims its own name in the pool.

**The service.** `svc.sh install` generates a unit named
`vsts.agent.<org>.<pool>.<agent>.service` and records that name in `.service`. The play reads
it from there rather than constructing it, because the name embeds the organisation and the
organisation is not something this repo writes down (README PII rule). Same reason the play
does not log it.

**The kubeconfig.** Written to `~azdo/.kube/config`, which is inside the install directory, so
kubectl and helm find it with no `KUBECONFIG` in any pipeline definition. The role finishes
with `kubectl auth can-i create deployment -n dev` as the service user — one call that proves
the token was read, the kubeconfig is valid, FW-003 permits the path and the RoleBinding
exists.

## The dev namespace family

Pipelines deploy into `dev` and into namespaces parented to it. Child names are free-form; a
namespace is a child because it carries `home.arpa/parent: dev` and for no other reason.

Kubernetes namespaces are flat, so the parent relationship is a label and Kyverno does what a
hierarchy controller would have. HNC was the obvious candidate and is archived — moved to
`kubernetes-retired` in April 2025, last release June 2023 — and running an unmaintained
webhook in front of every namespace operation is not a trade worth taking in a cluster this
repo otherwise keeps on a 2-year abandonment threshold.

Three rules, across two files in `kubernetes/apps/platform/azdo-deployer/files/`:

- **validate** (`namespace-fence.yaml`) — the deployer may only create, and only delete,
  namespaces carrying the label. This is the boundary RBAC cannot express: `create` on
  namespaces is cluster-wide by definition, so the constraint on *which* namespaces has to live
  at admission. Deletion is checked against `oldObject`, because `request.object` is null on
  DELETE.
- **mutate** — a child gets `pod-security.kubernetes.io/enforce: baseline` on the way in.
  Mutation precedes validation, so a pipeline satisfies `require-namespace-psa-label` without
  knowing it exists. The anchor only fills in a missing label: a child declaring `restricted`
  keeps it, and one declaring `privileged` is still rejected by `kyverno-policies`.
- **generate** — the `RoleBinding` and the memory `LimitRange`, written into every child and
  healed if edited or deleted. This is the propagation the hierarchy would have given.

Two policies in two files rather than one, and the split is forced twice over. The engine
forces it: rules matching on `subjects` read `request.userInfo`, which Kyverno cannot evaluate
in background scans, so they must set `background: false` — and generate rules need the
background controller. CI forces the file boundary on top of that: `kyverno apply` supplies no
requester, and with none the CLI treats a subject-matched rule as matching *every* request, so
feeding it the fence fails the job on namespaces no pipeline will ever touch. The workflow
renders and checks `policies.yaml` only; `namespace-fence.yaml` is engine-checked nowhere,
which means a schema error in it surfaces as a stalled wave-2 sync rather than a red PR. Both
policies pin `failurePolicy: Fail`.

The generate rules need Kyverno's background controller to hold permission on the kinds they
create, including `bind` on the ClusterRole they reference (Kubernetes escalation prevention).
That grant is in `kubernetes/apps/security/kyverno/values.yaml`. Without it the rules report
success and produce nothing.

Children are invisible to `platform-limits`: that app is a static list synced at wave 3, and a
child appears months later. Its ceiling is generated instead, which is why the two values have
to stay equal.

## Cluster identity

`azdo-deployer` lives in `azdo-system`, which is **not** a namespace it has any rights in. A
credential a compromised pipeline could rewrite is not a constraint on that pipeline — the same
reasoning that keeps the ESO bootstrap credential alone in `external-secrets`.

Its permissions are one `ClusterRole` reached only through `RoleBinding`s, so they apply inside
the bound namespace and nowhere else: core workload kinds, `apps`, `batch`,
`networking.k8s.io`, `policy`, `autoscaling`, plus the CRDs a deployed app legitimately needs
(`traefik.io`, `external-secrets.io`, `keda.sh`, `monitoring.coreos.com`).

Deliberately absent:

- `pods/exec` and `pods/portforward` — exec is a lateral move to that pod's identity, and every
  pod in the family will have one.
- `roles` and `rolebindings` — a CI identity that can rewrite its own grant is not a boundary.
  Escalation prevention would cap it at what it already holds; the shape is still wrong.
- `limitranges` and `resourcequotas` — the ceiling is generated, not negotiable.
- cluster-scoped writes, with one exception below. A chart shipping its own CRDs therefore
  cannot be installed by an agent, which is intended: CRDs are platform-owned and belong in
  this repo (`../programming/gitops_apps.md`).

The exception is `get`, `create` and `delete` on `namespaces`, bound cluster-wide because
there is no namespaced form of it. No `update`/`patch`, so an existing namespace cannot be
relabelled into the family; no `list`/`watch`, so the cluster cannot be enumerated; and
`create` against an existing name fails, so nothing can be taken over. The create and delete
verbs are fenced by the validate rule above, and because that policy is fail-closed a Kyverno
outage denies them rather than unfencing them.

`cluster-admin` is never bound — `kyverno-policies`' `rbac-hardening` is fail-closed and would
reject it.

## How the token reaches the agents

The play reads the break-glass `talos-kubeconfig` from Key Vault on the control node, uses it
for one `kubectl get secret`, and templates the result into each LXC's kubeconfig. The endpoint
and CA come out of that same file rather than being restated here, so they cannot drift from
what Talos issued.

The alternative was a Key Vault copy of the token, and it was rejected because the token is
derived state: it is regenerated on every cluster rebuild and every time the Secret is
recreated. A vault copy would be a second statement of a value that changes without anyone
touching the vault, and its failure mode is silent — a stale token authenticates as nobody,
days later. Terraform cannot own it either without inverting the layering, since a resource
reading a wave-2 GitOps object would have to block on ArgoCD.

The cost is that the play holds cluster-admin for the duration of one read. It is written to a
mode-0600 tempfile on the control node, never copied to a host, and removed by the play's
`always` block so a failed run leaves nothing behind.

Rotation is deleting the token Secret, letting the controller refill it, and re-running the
play. `kubectl -n azdo-system create token azdo-deployer --duration=...` is the manual path if
a bounded credential is ever wanted instead.

## Idempotency

Most of this role converges files, unlike `technitium`, so `--check` reports something
meaningful. The parts that do not are the two guarded commands: `config.sh` is guarded on
`.agent` and `svc.sh` on `.service`, because neither is re-runnable. A second full run must
report `changed=0` for install, configure and service — a change on either of those tasks
means the guard is wrong, and re-registering an agent on every run is the failure mode the
guards exist to prevent.

The version assertions are the other half. They run after install and compare what is on disk
against the pins, which is what catches a server-driven agent upgrade.

## Secrets

| Secret | Use |
|---|---|
| `azdo-pat` | Registers the agent with the pool. Used once; revocable afterwards |
| `azdo-org-url` | The organisation URL, treated as PII |
| `talos-kubeconfig` | Read once per run to fetch the deployer token |

Details and scopes in `../secrets.md`.

## Versions

Four pins in `roles/azdo_agent/defaults/main.yml`, kept fresh by a Renovate custom manager.
Upgrade behaviour, and the in-place agent upgrade that trips the assertion, in `upgrades.md`.

## Not covered

- **Builds.** These agents have no container runtime and no build toolchain. Compiling,
  testing and image building happen on Microsoft-hosted agents; that split is what keeps these
  containers unprivileged with no nesting.
- **Pipeline YAML.** It lives with the code being deployed, not here.
- **The agent's own auto-update.** Azure DevOps drives it; the role only notices.
- **NTP.** An unprivileged LXC has `CAP_SYS_TIME` dropped and follows the host clock, so there
  is no chrony here to match the core-infra pair.
