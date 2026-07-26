#!/usr/bin/env python3
"""Check the DNS record set against the authoritative address plan.

`documentation/networking/allocations.md` owns the addressing; the A records in
`ansible/group_vars/core_infra.yml` are its projection into DNS. Nothing else
enforces that the two agree, and the failure mode is quiet: a device added to
the table but not to the record list simply has no name until someone notices
it does not resolve.

Two directions are checked.

  * Every managed record points at an address the table lists. Catches a typo
    and catches a record left behind after the table moved an address.
  * Every single-host row in the table either has a record or appears in
    NO_RECORD below with a reason. Adding a row therefore forces a decision
    rather than defaulting to silence.

Ranges (DHCP pools, the LoadBalancer pool) are not host rows and are skipped.
"""

from __future__ import annotations

import ipaddress
import pathlib
import re
import sys

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
ALLOCATIONS = REPO / "documentation" / "networking" / "allocations.md"
GROUP_VARS = REPO / "ansible" / "group_vars" / "core_infra.yml"

# Host addresses that deliberately carry no A record.
NO_RECORD = {
    "10.1.11.1": "router VLAN 11 sub-interface; the router's record is its VLAN 10 address",
    "10.0.13.1": "router VLAN 13 sub-interface; same",
    "10.0.15.1": "router VLAN 15 sub-interface; same",
    "10.1.12.11": "VLAN 12 is an L2-only island - a name resolving here reaches nothing",
    "10.1.12.12": "as above",
    "10.1.12.13": "as above",
}

IPV4 = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")


def parse_allocations(text: str) -> dict[str, str]:
    """Return {ip: device name} for every single-host row of Address Assignments."""
    hosts: dict[str, str] = {}
    in_section = False

    for line in text.splitlines():
        if line.startswith("## "):
            in_section = line.strip() == "## Address Assignments"
            continue
        if not in_section or not line.startswith("|"):
            continue

        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 5:
            continue
        name, address = cells[0], cells[4]

        # Header and separator rows.
        if name in ("Device / Resource", "") or set(address) <= set("-: "):
            continue
        if not IPV4.match(address):
            continue

        try:
            ipaddress.IPv4Address(address)
        except ValueError:
            continue

        hosts[address] = name

    return hosts


def load_records(path: pathlib.Path) -> list[dict[str, str]]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    records = data.get("technitium_infra_records")
    if not isinstance(records, list):
        raise SystemExit(f"{path}: technitium_infra_records is missing or not a list")
    return records


def main() -> int:
    hosts = parse_allocations(ALLOCATIONS.read_text(encoding="utf-8"))
    if not hosts:
        raise SystemExit(f"{ALLOCATIONS}: parsed no host rows - has the table changed shape?")

    records = load_records(GROUP_VARS)
    errors: list[str] = []

    seen_names: dict[str, str] = {}
    seen_ips: dict[str, str] = {}
    for record in records:
        name, ip = record.get("name"), record.get("ip")
        if not name or not ip:
            errors.append(f"malformed record entry: {record!r}")
            continue
        if name in seen_names:
            errors.append(f"duplicate record name {name}")
        if ip in seen_ips:
            errors.append(f"{name} and {seen_ips[ip]} both point at {ip}")
        seen_names[name] = ip
        seen_ips[ip] = name

        if ip not in hosts:
            errors.append(
                f"{name} -> {ip} is not an address in {ALLOCATIONS.name}"
            )

    for ip, device in sorted(hosts.items(), key=lambda kv: ipaddress.IPv4Address(kv[0])):
        if ip in seen_ips or ip in NO_RECORD:
            continue
        errors.append(
            f"{device} ({ip}) has no A record - add one to "
            f"technitium_infra_records, or add it to NO_RECORD in {pathlib.Path(__file__).name} with a reason"
        )

    unused = sorted(set(NO_RECORD) - set(hosts))
    for ip in unused:
        errors.append(f"NO_RECORD lists {ip}, which no longer appears in {ALLOCATIONS.name}")

    if errors:
        print(f"{len(errors)} problem(s):\n", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print(
        f"ok: {len(records)} records against {len(hosts)} host rows "
        f"({len(NO_RECORD)} deliberately unnamed)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
