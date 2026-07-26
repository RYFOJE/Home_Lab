# Vendored manifests: where they came from and how to update them

Multus and whereabouts publish no Helm chart, so `multus.tf` applies upstream
release manifests copied into this directory verbatim. Nothing else in this
repository is vendored.

Without this file the copies had no recorded origin: the version was visible
only in the image tags inside them, and there was no way to tell which upstream
commit a copy corresponded to or whether a newer one existed.

## What is vendored

| File | Upstream repository | Pinned at | Source path |
|---|---|---|---|
| `multus-daemonset-thick.yaml` | `k8snetworkplumbingwg/multus-cni` | `v4.3.0` | `deployments/multus-daemonset-thick.yml` |
| `whereabouts-daemonset-install.yaml` | `k8snetworkplumbingwg/whereabouts` | `v0.9.4` | `doc/crds/daemonset-install.yaml` |
| `whereabouts-whereabouts.cni.cncf.io_ippools.yaml` | `k8snetworkplumbingwg/whereabouts` | `v0.9.4` | `doc/crds/whereabouts.cni.cncf.io_ippools.yaml` |
| `whereabouts-whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml` | `k8snetworkplumbingwg/whereabouts` | `v0.9.4` | `doc/crds/whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml` |
| `whereabouts-whereabouts.cni.cncf.io_nodeslicepools.yaml` | `k8snetworkplumbingwg/whereabouts` | `v0.9.4` | `doc/crds/whereabouts.cni.cncf.io_nodeslicepools.yaml` |

The image tags inside these files are the authoritative version record, and
Renovate tracks them directly (`renovate.json`, the vendored-manifest custom
manager). A Renovate PR that bumps only a tag is therefore a signal to refresh
the whole file, not a change to merge on its own — the manifest around the tag
moves too.

## Updating

```bash
curl -fsSLo terraform/40-kube-networking/manifests/multus-daemonset-thick.yaml \
  https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.3.0/deployments/multus-daemonset-thick.yml
```

Substitute the new tag, repeat for each row above, then diff. Two things to
re-check on every refresh, because upstream changes them without notice:

- **The images must stay on an allow-listed registry with an explicit tag.**
  `scripts/check_cluster_policy.py` runs the same image checks over this
  directory that it runs over every chart, so CI catches a violation — but it
  catches it after the copy, not before.
- **Multus's file is upstream's own quickstart manifest.** Its header says so:
  it deliberately does not cover upgrade or uninstall scenarios. Applying a new
  copy over a running cluster is not something upstream tests, so read the
  DaemonSet diff rather than trusting the apply.

## Why this is vendored rather than packaged

`k8snetworkplumbingwg` publishes no Helm repository for either project. The
alternative — building a local chart around the manifests — would mean
maintaining a translation layer that has to be re-derived on every upstream
change, which is more surface than the copy it replaces.
