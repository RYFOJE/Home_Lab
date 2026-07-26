# Key Vault Secrets

All secrets live in Azure Key Vault `rj-london` (resource group `terraform`) and are read
at plan/apply time via `data.azurerm_key_vault_secret` — nothing secret is committed to
this repo (README rule; the public domain name counts). Every layer therefore requires
`az login` before `terraform plan`.

In-cluster secrets are the exception to the Terraform path: they are pulled from the same
vault by External Secrets Operator (`kubernetes/apps/security/external-secrets`) through the single
`azure-kv` ClusterSecretStore. Those keys are namespaced — named `<namespace>--<name>`
(double dash) — and a Kyverno policy (`kubernetes/apps/security/cluster-secrets`) refuses any
`ExternalSecret` whose `remoteRef.key` does not start with its own namespace, so a
namespace cannot read another's secrets (`programming/gitops_apps.md`). The three secrets
consumed directly by Terraform to bootstrap that path (below) are unprefixed.

`ansible/` is a third path, for both its plays: neither the core-infra DNS servers nor the
Azure DevOps agents are a Terraform layer, and neither holds an in-cluster identity, so each
play reads its secrets on the control node with `az keyvault secret show`
(`infrastructure/core_infra.md`, `infrastructure/azdo_agents.md`).

**Terraform creates exactly one Secret in the cluster**: `azure-kv-creds` in the
`external-secrets` namespace (60-argo-cd `gitops.tf`), the credential ESO cannot fetch for
itself. Everything else, including the Cloudflare token cert-manager's DNS-01 solver reads,
arrives through ESO — so no other credential sits in a Terraform state file, and rotating
one is a vault edit rather than an apply.

A missing secret fails the consuming layer at plan time with a `KeyVault` data-source
error naming the secret — create it with:

```
az keyvault secret set --vault-name rj-london --name <name> --value <value>
```

## Secrets

| Secret name | Consumed by | Purpose |
|---|---|---|
| `unifi-password` | `10-network` | Password for the local UniFi controller user Terraform authenticates as (`unifi_username` in `terraform.tfvars`, created during bootstrap — see `networking/physical_network.md`) |
| `wlan-passphrase-home` | `10-network` | WPA3 passphrase for the `home` SSID (VLAN 13, trusted devices) |
| `wlan-passphrase-home-iot` | `10-network` | WPA2 passphrase for the `home-iot` SSID (VLAN 15, smart-home devices) |
| `wlan-passphrase-home-mgmt` | `10-network` | WPA3 passphrase for the `home-mgmt` SSID (VLAN 10). Joining this SSID grants full management access — the passphrase is an admin credential |
| `proxmox-api-token` | `20-proxmox` | Proxmox VE API token for the bpg/proxmox provider, full form `user@realm!tokenid=<uuid>` |
| `technitium-admin-password` | `ansible/` (core-infra) | Admin account for the Technitium web console (5380, LXC-FW-004) and the API the playbook configures the server through. Read on the control node with `az keyvault secret show`, not by Terraform — the DNS servers are not a Terraform-managed layer (`infrastructure/core_infra.md`). Set it before the first run: the playbook replaces the shipped `admin`/`admin` with this value and the default never survives |
| `cert-manager--cloudflare-dns-api-token` | ESO (`cert-manager`), `50-cloudflare` | Cloudflare API token for cert-manager's ACME DNS-01 solver and for 50-cloudflare (tunnel + public DNS records). Scopes: Zone → DNS → Edit and Zone → Zone → Read on the public domain's zone only, plus Account → Cloudflare Tunnel → Edit (the tunnel token data source requires Edit, not Read). Carries the `cert-manager--` prefix because that is the namespace ESO syncs it into, which is what the Kyverno prefix rule checks; 50-cloudflare reading the same secret by that name is deliberate — one authoritative copy beats two that can drift. 40-kube-networking no longer reads it at all, so the token is not in that layer's state |
| `cloudflare-account-id` | `50-cloudflare` | Cloudflare account ID owning the tunnel and the zone. Treated as a secret alongside the domain (PII rule) |
| `public-domain` | `40-kube-networking`, `50-cloudflare`, `60-argo-cd`, `ansible/` | The owned public domain served by the Traefik edge (wildcard certificate, split-horizon DNS). Stored as a secret because domain names are treated as PII in this repo. The Ansible consumer is the internal half of the split horizon — the zone Technitium hosts for it (`infrastructure/core_infra.md`) |
| `cert-manager--cloudflare-dns-api-token` *(in-cluster path)* | ESO (`cluster-secrets`) | Same secret as the row above, reached the other way: `kubernetes/apps/security/cluster-secrets` renders an `ExternalSecret` into the `cert-manager` namespace, which ESO syncs into the `cloudflare-api-token` Secret the `letsencrypt` ClusterIssuer's DNS-01 solver reads. Rotating the token is therefore a vault edit; cert-manager picks it up within `refreshInterval` |
| `acme-email` | `40-kube-networking` | Contact email for the Let's Encrypt ACME account (expiry/problem notices). The only Cloudflare/ACME value 40-kube-networking still reads |
| `argocd-admin-password-bcrypt` | `60-argo-cd` | Pre-computed bcrypt hash of the ArgoCD UI admin password, set verbatim on the chart (`configs.secret.argocdServerAdminPassword`). Stored as the hash, not the plaintext, because Terraform's `bcrypt()` generates a new salt every plan and would roll the release on every apply. Generate with `argocd account bcrypt --password <pw>` |
| `azure-kv-sp-client-id` | `60-argo-cd` | App (client) ID of the Service Principal External Secrets Operator authenticates to Key Vault with. Written by Terraform into the `azure-kv-creds` Secret in the `external-secrets` namespace (`gitops.tf`) -- the one credential that cannot come from ESO itself |
| `azure-kv-sp-client-secret` | `60-argo-cd` | Client secret of that Service Principal. Same handling as `azure-kv-sp-client-id`. Grant it `get` on this vault's secrets only |
| `monitoring--grafana-admin-password` | ESO (`kube-prometheus-stack`) | Grafana UI admin password. Synced by ESO into the `grafana-admin` Secret in `monitoring`; consumed via `grafana.admin.existingSecret` |
| `monitoring--discord-webhook-url` | ESO (`kube-prometheus-stack`) | Discord webhook Alertmanager delivers alerts to. Synced by ESO into the `alertmanager-discord` Secret in `monitoring`, referenced by `webhook_url_file` |
| `cloudflared--tunnel-token` | ESO (`cloudflared`) | Cloudflare Tunnel token. The one secret Terraform **writes** (50-cloudflare `tunnel-token.tf`) rather than reads — the tunnel is a Terraform resource, so the token cannot pre-exist in the vault. Synced by ESO into the `cloudflared-token` Secret; rotation requires a `rollout restart` of the Deployment (pods read `TUNNEL_TOKEN` at start) |
| `databases--postgres-superuser-password` | ESO (`postgres`) | Password for the PostgreSQL `postgres` superuser. Synced by ESO into the `postgres-superuser` basic-auth Secret in `databases` and set on the Cluster's `superuserSecret`, which the operator reads only because `enableSuperuserAccess: true` accompanies it — that field defaults to false, and while false the secret is ignored and the password blanked to `NULL`. The username is fixed in the manifest, not stored here (`infrastructure/databases.md`) |
| `databases--postgres-app-password` | ESO (`postgres`) | Password for the `app` role that owns the initial database. Consumed at bootstrap via `bootstrap.initdb.secret` and thereafter by clients. The role is also declared under `managed.roles`, so the operator reconciles the password continuously and rotation is a vault edit rather than a manual `ALTER ROLE` |
| `talos-talosconfig` | nothing (break-glass) | Client config for `talosctl` — node-level control of all three machines. **Written**, never read: 30-talos `kv.tf` publishes it so the loss of `30-talos.tfstate` does not also cost admin access to a live cluster (`infrastructure/disaster_recovery.md`). Retrieve with `az keyvault secret show` |
| `talos-kubeconfig` | `ansible/` (azdo-agent), break-glass | cluster-admin kubeconfig for the kube API. Written by 30-talos `kv.tf` for the same reason as `talos-talosconfig`; downstream Terraform layers still consume the kubeconfig via `terraform_remote_state`, not from here. It has one routine reader: `ansible/azdo-agent.yml` uses it on the control node for a single `kubectl get secret`, to read the `azdo-deployer` ServiceAccount token and template a scoped kubeconfig onto the agent LXCs. That token is derived state — regenerated on every cluster rebuild — so a Key Vault copy of it would drift silently; reading it live is what avoids that (`infrastructure/azdo_agents.md`). The admin credential is written to a mode-0600 tempfile, never leaves the control node, and is removed by the play's always-block |
| `azdo-pat` | `ansible/` (azdo-agent) | Azure DevOps personal access token the agents register with. Scope: **Agent Pools (Read & manage)** and nothing else. Used once per host by `config.sh`; the agent negotiates its own credential afterwards and stores it in `.credentials`, so the PAT can be revoked once both agents are Online. Read on the control node with `az keyvault secret show`, not by Terraform — the agents are not a Terraform-managed layer (`infrastructure/azdo_agents.md`) |
| `azdo-org-url` | `ansible/` (azdo-agent) | The Azure DevOps organisation URL (`https://dev.azure.com/<org>`). Stored as a secret because the organisation name identifies the account, the same treatment `public-domain` and `cloudflare-account-id` get (PII rule). It also ends up inside the systemd unit name `svc.sh` generates, which is why the play reads that name from a file and never logs it |

WLAN passphrase names follow the pattern `wlan-passphrase-<wlan key>` with underscores in
the `wlan_configs` key replaced by dashes (`10-network/main.tf`); adding an SSID means
adding a matching secret.

`30-talos` reads no Key Vault secrets — its credentials (Talos machine secrets,
kubeconfig) are generated into Terraform state and passed between layers via
`terraform_remote_state`. It is the only layer that writes to the vault without reading
from it: `talos-talosconfig` and `talos-kubeconfig` above are break-glass copies, so the
one layer whose state is unrecoverable is not also the one layer whose credentials are.
`talos-talosconfig` has stayed break-glass-only; `talos-kubeconfig` has one routine reader
(the row above), and the asymmetry is deliberate — node-level control never became routine.
The machine secrets themselves are deliberately **not** copied — they are the cluster's
root of trust, and a second copy is a second thing to compromise for no recovery benefit
(holding them without the state file still does not let Terraform manage the cluster).

Adding an in-cluster secret for an app: create the Key Vault secret as
`<namespace>--<name>`, then add an `ExternalSecret` to that app referencing `key:
<namespace>--<name>` and the `azure-kv` ClusterSecretStore. No Terraform change — ESO and
the Kyverno policy handle it. Only new bootstrap-level secrets (consumed by Terraform
before ESO exists) go through `data.azurerm_key_vault_secret`.
