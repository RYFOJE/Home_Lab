# Manual work inventory

This inventory records the actions that require human participation to provision, operate, recover, or upgrade the homelab. It distinguishes physical or trust-establishment work from work that belongs in Terraform, Ansible, GitOps, or a recovery procedure.

Terraform, Ansible, and GitOps ownership boundaries are defined in [GitOps applications](../programming/gitops_apps.md), [core infrastructure](core_infra.md), [Azure DevOps agents](azdo_agents.md), and [disaster recovery](disaster_recovery.md).

## Classification

| Classification | Meaning |
|---|---|
| Necessary | A physical action, root-of-trust decision, or controlled operational approval that automation cannot replace. |
| Security-sensitive | Necessary work that handles an administrative identity, credential, recovery artifact, or trusted device identity. |
| Automatable | Work that belongs in declared infrastructure/configuration management, including validation and evidence collection. |
| Dangerous | A recovery or migration action with destructive or broad blast radius. It is never part of normal deployment. |
| Undocumented | An external dependency that must gain a documented owner and recovery path. |

## Provisioning and trust bootstrap

| Action | Classification | Current owner | Target owner or control | Dependency |
|---|---|---|---|---|
| Rack, cable, power, and replace physical network, compute, and backup hardware. | Necessary | Operator | Asset, cabling, and hardware inventory. | Physical site |
| First boot the UniFi gateway and create the limited local administrator used by the UniFi Terraform provider. | Necessary; security-sensitive | Operator | Provider-specific bootstrap identity with minimum privileges. | Gateway physical access |
| Adopt UniFi devices and confirm their hardware identity and MAC address. | Necessary; security-sensitive | Operator | Discovery/import workflow produces validated site inventory inputs after adoption. | Gateway bootstrap |
| Install Proxmox and form the initial Proxmox cluster. | Necessary | Operator | Host configuration after installation is declarative. | Physical server access |
| Configure Proxmox host bridges, VLAN awareness, storage-network MTU, DNS, NTP, repositories, and trusted certificates. | Automatable | Manual | Proxmox host configuration management with preflight validation. | Proxmox bootstrap |
| Create Azure resource group, Terraform backend, Key Vault, RBAC, locks, retention/protection settings, and deployment identities. | Automatable; undocumented | Manual/external | Separate foundation Terraform state and recovery runbook. | Azure tenant access |
| Create Cloudflare zone/account identities and scoped API tokens. | Automatable; security-sensitive | Manual/external | Foundation identity configuration; secret values remain outside Git. | Cloudflare account access |
| Configure GitHub branch protection, required review, CODEOWNERS, and Azure DevOps organization/pool policy. | Automatable; undocumented | Manual/external | Provider-backed policy configuration or a documented external-control runbook. | GitHub and Azure DevOps administration |
| Authenticate to Azure and obtain an initial break-glass administrative session. | Necessary; security-sensitive | Operator | Short-lived interactive authentication and audited emergency-access procedure. | Azure identity |
| Populate initial Key Vault secret values. | Necessary; security-sensitive | Operator | Values remain outside Git; secret metadata, expiry, consumer coverage, and rotation evidence are automated. | Key Vault and secret source |
| Replace placeholder UniFi IDs, device MACs, and Proxmox SSH-key material before first apply. | Necessary under the current implementation | Operator | Terraform rejects unresolved placeholders and reads a validated site inventory. | Device adoption and operator key |
| Import the existing Proxmox `local` datastore into Terraform state. | Necessary for adoption; dangerous | Operator | Saved plan, exact target verification, peer review, and post-import plan. | Existing Proxmox datastore |

## Deployment and routine operation

| Action | Classification | Current owner | Target owner or control | Dependency |
|---|---|---|---|---|
| Apply Terraform layers in dependency order. | Necessary | Operator | Task runner or deployment pipeline with layer gates and independent state. | Azure authentication and external foundations |
| Run `ansible/core-infra.yml` after layer 20 and before layer 30. | Necessary | Operator | Orchestrated deployment stage. | Core-infra LXCs and Key Vault secrets |
| Configure chrony on the core-infrastructure LXCs. | Automatable | Manual | `core-infra` Ansible role. | Core-infra LXCs |
| Apply layer 40 immediately after Talos bootstrap. | Necessary | Operator | Explicit pre-CNI and post-CNI health gates. | Layer 30 |
| Apply layers 50 and 60 after cluster networking. | Necessary | Operator | Orchestrated stages with dependency checks. | Layer 40 |
| Configure Azure DevOps agents after Argo CD creates the deployer ServiceAccount. | Necessary | Operator | Orchestrated final stage gated on ServiceAccount readiness. | Argo CD convergence |
| Use repeated `terraform -target` to perform control-plane changes node by node. | Dangerous | Operator | Serialized Talos change workflow with quorum, drain, and health gates. | Healthy control plane |
| Create or update public DNS manually in DNAT edge mode. | Automatable | Operator | Terraform owns tunnel and DNAT DNS records. | Declared WAN/DDNS target |
| Restart workloads manually after secret rotation. | Automatable | Operator | Workload identity where possible; otherwise controlled secret-change rollout. | Rotated secret |

## Backup, recovery, and migration

| Action | Classification | Current owner | Target owner or control | Dependency |
|---|---|---|---|---|
| Install or replace PBS hardware and storage. | Necessary | Operator | Asset inventory and physical-install procedure. | Backup hardware |
| Configure PBS firewall, NFS/storage access, backup jobs, retention, off-site copy, and restore identities. | Automatable | Manual/absent | Foundation infrastructure and backup configuration. | PBS hardware and object/off-site storage |
| Export Talos break-glass credentials to local files during recovery. | Necessary emergency action; dangerous; security-sensitive | Operator | Restricted temporary storage, explicit cleanup, audit trail, and credential rotation after use. | Operations vault access |
| Restore Terraform state, import or move resources, or select an earlier backend-state version. | Necessary emergency/migration action; dangerous | Operator | Saved backup, exact resource targeting, peer review, and post-operation plan. | State backend recovery |
| Delete failed pods/PVCs or clear Longhorn orphan state. | Necessary emergency action; dangerous | Operator | Exact object selection, backup verification, and documented decision gate. | Storage incident |
| Choose Talos single-node replacement, etcd quorum recovery, or full new-cluster recovery. | Necessary emergency decision; dangerous | Operator | Separate tested runbooks for each path. | Incident classification and backups |
| Perform etcd, CNPG PITR, Longhorn volume, Git, vault, and Terraform-state restore drills. | Necessary | Operator | Scheduled evidence-producing recovery exercise. | Automated backups |
| Verify backup freshness, restore success, retention, immutability, and off-site copy. | Automatable | Manual/absent | Monitoring, alerting, and periodic restore test evidence. | Backup platform |

## Security, identity, and lifecycle work

| Action | Classification | Current owner | Target owner or control | Dependency |
|---|---|---|---|---|
| Rotate Azure, Cloudflare, Talos, Terraform, ESO, certificate, and Azure DevOps credentials. | Necessary; security-sensitive | Operator | Identity-specific runbooks, expiry alerts, controlled rollout, revocation verification, and short-lived/federated credentials. | Replacement credential |
| Confirm SSH host keys after host rebuild. | Necessary; security-sensitive | Operator | Trusted fingerprint source from Proxmox console/API or an SSH host CA. | Rebuilt host identity |
| Review major Kubernetes, Talos, Cilium, storage, database, chart, and CRD upgrades. | Necessary; security-sensitive | Operator | Approval gate with compatibility, schema/render, backup, rollback, and maintenance evidence. | Tested upgrade artifact |
| Approve destructive storage, firewall, state, or cluster-recovery changes. | Necessary; dangerous | Operator | Explicit change record with target, backup, rollback, and verification. | Saved plan/runbook |
| Scan and verify downloaded binaries, chart provenance, images, CI actions, and dependency updates. | Automatable | Partial CI/manual | CI controls using immutable revisions, checksums/signatures, SBOMs, and vulnerability results. | Build pipeline |

## Actions that are not normal operations

The following actions are recovery or migration procedures only:

- Terraform state rollback, import, or resource move.
- Proxmox datastore import.
- Direct deletion of pods, PVCs, or Longhorn orphan metadata.
- Talos bootstrap after an existing cluster has been lost.
- Manual export of break-glass configuration.
- Emergency DNS or edge-mode intervention.

Each requires an exact target, a current backup or an explicit acknowledgement that recovery is unavailable, an approval decision, and a verification step.

## Automation backlog

1. Foundation state for Azure, Cloudflare identities, backend/vault protection, and external policy controls.
2. Proxmox host bridge/VLAN/MTU, DNS, NTP, repository, and certificate configuration.
3. Validated site-inventory generation and Terraform input checks.
4. Talos staged health and serialized control-plane mutation.
5. Declarative DNAT DNS and secret-change rollout.
6. PBS/Longhorn/CNPG/etcd backup configuration, external monitoring, and restore evidence.
7. Credential lifecycle automation and workload identity.
8. CI enforcement for plans, schemas, supply-chain verification, security scanning, and recovery tests.
