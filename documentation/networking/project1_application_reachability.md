# Project 1 Application Reachability Guide

This guide explains how to publish or restrict access to applications deployed in Project 1 (`VLAN 11`, `10.1.11.0/24`) on the k3s cluster.

## Quick Decision Table

| Goal | Kubernetes Pattern | Network Outcome |
|---|---|---|
| Externally reachable | `Ingress` + `LoadBalancer` Service (MetalLB IP) | Reachable from trusted clients and optionally from the internet (if WAN forwarding is added) |
| Internal only (inside cluster) | `ClusterIP` Service only | Reachable only by pods/services inside the cluster |
| Internal only (from home network clients) | Internal `Ingress`/`LoadBalancer` with firewall allow-list | Reachable from selected internal VLANs only |
| Cross-namespace communication | `ClusterIP` + explicit `NetworkPolicy` allows | Only approved namespaces/workloads can connect |

## 1) Make an Application Externally Reachable

Use this when users outside the cluster must access the app.

1. Deploy app with a `ClusterIP` Service.
2. Publish through an ingress controller backed by a `LoadBalancer` Service (MetalLB pool `10.1.11.50-99`).
3. Create DNS record pointing to the ingress/load balancer IP.
4. Add TLS (recommended, required if internet exposed).
5. If true internet exposure is needed, add WAN-to-LAN port forwarding on the edge router to the ingress IP and only required ports (typically 443).

Security minimums:
- Expose only ingress, not random node ports.
- Restrict allowed source networks at router/firewall where possible.
- Keep admin endpoints separate from public routes.

## 2) Keep an Application Internal Only

### Cluster-internal only

Use `ClusterIP` and do not create `Ingress`, `NodePort`, or `LoadBalancer` resources.

### Internal home-network only

Use `Ingress`/`LoadBalancer` but limit reachability with router/firewall policy to approved internal VLANs only (for example, trusted devices VLAN). Do not create WAN forwarding.

Security minimums:
- Deny by default, then allow only required source ranges.
- Keep management UIs on internal-only paths.

## 3) Allow Communication Between Namespaces

By default, pods can often talk across namespaces unless restricted. For predictable behavior:

1. Apply default-deny `NetworkPolicy` per namespace.
2. Add explicit allow policies from source namespace/workload to destination Service port.
3. Use service DNS names (`service.namespace.svc.cluster.local`) to make traffic intent clear.
4. Document producer/consumer namespace dependencies.

This keeps traffic least-privilege while still enabling required service-to-service calls.

## 4) Other Useful Access Cases

- Admin-only exposure: publish app only to management/trusted subnet, not all internal clients.
- VPN-only access: keep service private and require VPN into the home network before access.
- Temporary debugging access: short-lived ingress/port-forward, then remove immediately.
- Egress-only jobs: workloads that call external APIs but are never inbound-reachable.
- Shared platform services: central services (DNS, auth, monitoring) consumed by many namespaces using explicit `NetworkPolicy` rules.

## Recommended Default for New Apps (Project 1)

1. Start as `ClusterIP` (private by default).
2. Add `NetworkPolicy` default deny + explicit allows.
3. Promote to internal ingress only if needed.
4. Promote to internet exposure only with TLS, firewall restrictions, and clear operational ownership.
