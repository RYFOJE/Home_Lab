# Key Vault Secrets

All secrets live in Azure Key Vault `rj-london` (resource group `terraform`) and are read
at plan/apply time via `data.azurerm_key_vault_secret` — nothing secret is committed to
this repo (README rule; the public domain name counts). Every layer therefore requires
`az login` before `terraform plan`.

In-cluster secrets are the exception to the Terraform path: they are pulled from the same
vault by External Secrets Operator (`kubernetes/apps/external-secrets`) through the single
`azure-kv` ClusterSecretStore. Those keys are namespaced — named `<namespace>--<name>`
(double dash) — and a Kyverno policy (`kubernetes/apps/cluster-secrets`) refuses any
`ExternalSecret` whose `remoteRef.key` does not start with its own namespace, so a
namespace cannot read another's secrets (`programming/gitops_apps.md`). The three secrets
consumed directly by Terraform to bootstrap that path (below) are unprefixed.

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
| `cloudflare-dns-api-token` | `40-kube-networking`, `50-cloudflare` | Cloudflare API token for cert-manager's ACME DNS-01 solver and the 50-cloudflare layer (tunnel + public DNS records). Scopes: Zone → DNS → Edit and Zone → Zone → Read on the public domain's zone only, plus Account → Cloudflare Tunnel → Edit (the tunnel token data source requires Edit, not Read) |
| `cloudflare-account-id` | `50-cloudflare` | Cloudflare account ID owning the tunnel and the zone. Treated as a secret alongside the domain (PII rule) |
| `public-domain` | `40-kube-networking`, `50-cloudflare`, `60-argo-cd` | The owned public domain served by the Traefik edge (wildcard certificate, split-horizon DNS). Stored as a secret because domain names are treated as PII in this repo |
| `acme-email` | `40-kube-networking` | Contact email for the Let's Encrypt ACME account (expiry/problem notices) |
| `argocd-admin-password-bcrypt` | `60-argo-cd` | Pre-computed bcrypt hash of the ArgoCD UI admin password, set verbatim on the chart (`configs.secret.argocdServerAdminPassword`). Stored as the hash, not the plaintext, because Terraform's `bcrypt()` generates a new salt every plan and would roll the release on every apply. Generate with `argocd account bcrypt --password <pw>` |
| `azure-kv-sp-client-id` | `60-argo-cd` | App (client) ID of the Service Principal External Secrets Operator authenticates to Key Vault with. Written by Terraform into the `azure-kv-creds` Secret in the `external-secrets` namespace (`gitops.tf`) -- the one credential that cannot come from ESO itself |
| `azure-kv-sp-client-secret` | `60-argo-cd` | Client secret of that Service Principal. Same handling as `azure-kv-sp-client-id`. Grant it `get` on this vault's secrets only |
| `monitoring--grafana-admin-password` | ESO (`kube-prometheus-stack`) | Grafana UI admin password. Synced by ESO into the `grafana-admin` Secret in `monitoring`; consumed via `grafana.admin.existingSecret` |
| `monitoring--discord-webhook-url` | ESO (`kube-prometheus-stack`) | Discord webhook Alertmanager delivers alerts to. Synced by ESO into the `alertmanager-discord` Secret in `monitoring`, referenced by `webhook_url_file` |
| `cloudflared--tunnel-token` | ESO (`cloudflared`) | Cloudflare Tunnel token. The one secret Terraform **writes** (50-cloudflare `tunnel-token.tf`) rather than reads — the tunnel is a Terraform resource, so the token cannot pre-exist in the vault. Synced by ESO into the `cloudflared-token` Secret; rotation requires a `rollout restart` of the Deployment (pods read `TUNNEL_TOKEN` at start) |

WLAN passphrase names follow the pattern `wlan-passphrase-<wlan key>` with underscores in
the `wlan_configs` key replaced by dashes (`10-network/main.tf`); adding an SSID means
adding a matching secret.

`30-talos` reads no Key Vault secrets — its credentials (Talos machine secrets,
kubeconfig) are generated into Terraform state and passed between layers via
`terraform_remote_state`.

Adding an in-cluster secret for an app: create the Key Vault secret as
`<namespace>--<name>`, then add an `ExternalSecret` to that app referencing `key:
<namespace>--<name>` and the `azure-kv` ClusterSecretStore. No Terraform change — ESO and
the Kyverno policy handle it. Only new bootstrap-level secrets (consumed by Terraform
before ESO exists) go through `data.azurerm_key_vault_secret`.
