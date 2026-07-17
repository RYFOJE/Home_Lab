# Key Vault Secrets

All secrets live in Azure Key Vault `rj-london` (resource group `terraform`) and are read
at plan/apply time via `data.azurerm_key_vault_secret` — nothing secret is committed to
this repo (README rule; the public domain name counts). Every layer therefore requires
`az login` before `terraform plan`.

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
| `public-domain` | `40-kube-networking`, `50-cloudflare` | The owned public domain served by the Traefik edge (wildcard certificate, split-horizon DNS). Stored as a secret because domain names are treated as PII in this repo |
| `acme-email` | `40-kube-networking` | Contact email for the Let's Encrypt ACME account (expiry/problem notices) |

WLAN passphrase names follow the pattern `wlan-passphrase-<wlan key>` with underscores in
the `wlan_configs` key replaced by dashes (`10-network/main.tf`); adding an SSID means
adding a matching secret.

`30-talos` reads no Key Vault secrets — its credentials (Talos machine secrets,
kubeconfig) are generated into Terraform state and passed between layers via
`terraform_remote_state`.
