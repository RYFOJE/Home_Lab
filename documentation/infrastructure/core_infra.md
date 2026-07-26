# core-infra: DNS

The two `core-infra` LXCs on VLAN 10 (`10.0.10.4` primary, `10.0.10.5` secondary) run
Technitium DNS and chrony. Placement, redundancy, and the zone design are decided in
`../networking/allocations.md`; this page covers how the DNS half is deployed.

| | Owner |
|---|---|
| The containers, their addressing, the PVE firewall around them | `terraform/20-proxmox` |
| Technitium: install, server settings, zones, records | `ansible/` (this page) |
| chrony | manual |

Proxmox LXCs have no cloud-init, so nothing configures a container's contents at create
time. Ansible is that step, and it runs between layers 20 and 30 of a rebuild
(`disaster_recovery.md`).

## Running it

```bash
cd ansible && ansible-playbook core-infra.yml
```

Requires `ansible-core` ≥ 2.15 on the control node, `az login` (both values it needs are
Key Vault secrets), a control node on VLAN 10 (LXC-FW-005 permits SSH to `.4`/`.5` from
VLAN 10 only, matching LXC-FW-004's posture for the web console), and the private half of
`core_infra_ssh_public_key` from `terraform/20-proxmox/terraform.tfvars`.

The play is `serial: 1` over an inventory that lists the primary first: the secondary's
zones are created as secondaries pointing at `10.0.10.4`, so the primary must already be
serving them.

## Bootstrap ordering

`20-proxmox` points each container's `/etc/resolv.conf` at `10.0.10.4` and `10.0.10.5` —
themselves. On a new container nothing answers there, so `apt` and
`download.technitium.com` fail until something else resolves. The play writes a public
resolver into `resolv.conf` before anything needs DNS and restores the pair in an
`always` block, so a failed run does not leave the temporary state behind. The restored
content is byte-identical to what Terraform writes, so a later `terraform apply` has
nothing to reassert.

FW-013 is what makes this work: it permits `10.0.10.4/.5` outbound on 53, 123 and 443.
VLAN 11 carries no equivalent allow, which is the reason DNS must exist before `30-talos`
rather than alongside it — a Talos node cannot bootstrap its way out of the same problem.

The same rule constrains forwarding: DNS-over-TLS is 853 and would be dropped. The
forwarder protocol is plain 53, and DoH over 443 is the only encrypted option available
without changing FW-013.

## What the role configures

**Server settings** — recursion restricted to private networks, upstream forwarders,
blocklist feeds and their refresh interval. VLAN 15 is given internal DNS specifically so
the blocklists apply to IoT firmware.

**Zones** — `home.arpa` and the public domain, Primary on `.4` and Secondary on `.5`.
Primary zones carry transfer and notify options scoped to `10.0.10.5`; LXC-FW-003 in
`../networking/firewall_rules.yaml` is the network half of that.

**Records** — the A records of `home.arpa` are the Address Assignments table in
`../networking/allocations.md` projected into DNS; that table is authoritative and a new
device goes there first. The public domain zone holds exactly two records, apex and
wildcard, both → `10.1.11.51` (`../programming/publishing_apps.md`). The apex is not
redundant: a wildcard never matches the zone apex.

Adding a record is an entry in `technitium_infra_records` in
`ansible/group_vars/core_infra.yml` and a re-run. Per-app records are never added — the
wildcard covers every published app on both ingress classes.

## Keeping the records and the address plan in step

The record list is a second statement of the allocations table, and the two files exist
for different readers — one is the design document, the other is what Ansible applies.
`python scripts/check_dns_records.py` (PyYAML, nothing else) is what makes disagreement
loud, and CI runs it on any change to either file:

- every managed record points at an address the table lists — so a record left behind
  after the table moved an address is caught, which otherwise answers with a stale
  address rather than failing to answer;
- every single-host row in the table either has a record or appears in the script's
  `NO_RECORD` map with a reason. Adding a row forces the decision instead of defaulting
  to silence.

Six addresses are deliberately unnamed: the three router VLAN sub-interfaces (the router
is named at its VLAN 10 address) and the three VLAN 12 storage NICs, which sit on an
L2-only island where a resolved name would reach nothing. Ranges — the DHCP pools and the
LoadBalancer pool — are not host rows and are skipped.

## Idempotency

Technitium keeps its configuration in a binary file behind an HTTP API, not in a text
file, so the role calls the API with `ansible.builtin.uri` rather than templating config.
Two consequences:

- **Zones and records are reconciled.** The role lists what exists, creates what is
  missing, and corrects an A record whose address changed. `changed` is accurate and a
  second run is quiet.
- **Server settings and zone options are applied unconditionally and reported
  unchanged.** Diffing them against `settings/get` requires a type normalisation per key —
  the API accepts comma-separated strings and returns lists, accepts enum names and
  returns them cased differently — and would report drift that does not exist.

`--check` is meaningless for this role: in check mode the API calls do not run, so it
reports nothing rather than reporting no changes.

The API answers HTTP 200 with `{"status":"error"}` for logical failures. Every task
checks the body; a task that checked only the status code would pass on every failure.

Parameter names and enum spellings for the settings, zone options and records are held as
data in `ansible/group_vars/core_infra.yml`, not inline in tasks. Technitium has renamed
several across major versions, and this keeps such a bump a values edit.

## Secrets

| Secret | Use |
|---|---|
| `technitium-admin-password` | The admin account for the web console and the API |
| `public-domain` | The split-horizon zone name |

Both are read on the control node with `az keyvault secret show`. The role logs in with
the managed password, falls back to the shipped `admin`/`admin` on a fresh install, and
replaces it — the default never survives a first run. Every task that templates either
value sets `no_log`; `-e technitium_no_log=false` lifts that for a debugging run.

## Version

The official installer takes no version parameter and always fetches the current release,
so the version cannot be pinned at install time. Setting `technitium_version` makes the
run assert against what is installed instead. Upgrades: `upgrades.md`.

## Not covered

chrony is still installed and configured by hand. Zone *data* recovery is a Technitium
config backup restore, not a re-run — the playbook creates zones and the records it
manages, and knows nothing about anything added through the web console.
