# Publishing an App Behind Traefik

The cluster runs two Traefik instances (`terraform/40-kube-networking`, module
`traefik-instance`). An app selects which one carries its traffic — and
therefore whether it is reachable from the internet — by the **ingressClass**
it publishes under. Nothing else in the route changes.

| ingressClass | Instance | LB IP | Reachable from |
|---|---|---|---|
| `traefik-external` | traefik-external | 10.1.11.50 | Internet (Cloudflare Tunnel; WAN DNAT FW-017 in dnat mode) **and** the LAN, the latter via the fallback route below |
| `traefik-internal` | traefik-internal | 10.1.11.51 | LAN only — never port-forwarded. Also the LAN's entry point for every hostname |

`traefik-external` is the internet-facing edge. `traefik-internal` exists for
apps that must never be exposed to the internet — there is no DNAT to
10.1.11.51 and the tunnel's origin is the external instance, so the isolation
is topological, not a per-route setting.

Every LAN request lands on `traefik-internal` regardless of class: internal DNS
resolves the whole public domain to 10.1.11.51 (below). Routes it does not own
fall through its lowest-priority `lan-fallback` route to `traefik-external`, so
an external app answers on the same hostname, over the same certificate, from
the LAN and from the internet. The class still decides exposure — it decides
which instance holds the route, and only the external one is reachable from
outside.

Choose exactly one class per route: pick `traefik-external` for anything the
internet should reach, `traefik-internal` for LAN-only.

## Ingress

Set `spec.ingressClassName` to the chosen instance. The chart publishes an
`IngressClass` object of that name.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-app
spec:
  ingressClassName: traefik-external   # or traefik-internal
  rules:
    - host: my-app.<public domain>
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
  tls:
    - hosts:
        - my-app.<public domain>
      # No secretName: the instance's default wildcard cert is served (below).
```

## IngressRoute (Traefik CRD)

`IngressRoute` has no `ingressClassName` field; the class is selected by the
`kubernetes.io/ingress.class` annotation. The instance only processes routes
carrying its own class value.

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
  namespace: my-app
  annotations:
    kubernetes.io/ingress.class: traefik-external   # or traefik-internal
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`my-app.<public domain>`)
      kind: Rule
      services:
        - name: my-app
          port: 80
  tls: {}   # empty: use the instance's default wildcard cert
```

## TLS

Each instance holds a wildcard certificate for the public domain (`<domain>`
and `*.<domain>`), issued by cert-manager via Cloudflare DNS-01 and set as the
instance's default certificate (`TLSStore` `default`). A route that enables TLS
without naming a Secret is served this cert automatically — apps under the
public domain need no per-app certificate. Publish hostnames as
`something.<public domain>`.

The `web` entry point (port 80) permanently redirects to `websecure` (443), so
routes only need the HTTPS side.

## DNS

**No app needs a DNS record.** Publishing one is the Ingress and nothing else.

The Technitium internal zone for the public domain is two static records that
never change as apps come and go (Technitium is manual/Ansible —
`networking/allocations.md`):

```
@   A   10.1.11.51
*   A   10.1.11.51
```

The apex record is not redundant: a DNS wildcard never matches the zone apex,
so without it the bare domain fails to resolve on the LAN while working from
the internet.

Public DNS in tunnel mode is likewise two Terraform-managed records covering
every hostname — apex and wildcard CNAMEs → the tunnel
(`terraform/50-cloudflare`). In dnat mode public records are manual, at the WAN
IP, for published apps only.

An internal-only app therefore resolves publicly and is *reachable* publicly,
but the tunnel's origin is `traefik-external`, which holds no route for it —
the request gets a 404 and the app is never reached. That is the containment.
It also leaks nothing: the wildcard certificate keeps per-host names out of
certificate-transparency logs, and the wildcard CNAME means public DNS never
enumerates them.

### The fallback route

`lan-fallback` (an `IngressRoute` plus a `ServersTransport`, both created by
`terraform/40-kube-networking/traefik.tf`) is what lets one internal address
serve both classes. It lives in the `traefik-external` namespace but carries
`traefik-internal`'s ingressClass: the instances watch every namespace and are
separated by class alone, so the internal instance serves it while the Service
and transport references stay same-namespace and neither instance needs
`providers.kubernetesCRD.allowCrossNamespace`.

It matches `HostRegexp` on the public domain at `priority: 1`. Priority `0`
would be *ignored* — Traefik falls back to rule-length sorting, which ranks a
long regexp above the `Host()` rules this must never shadow. Real routes sort
in the 20–40 range, so 1 is unconditionally last.

The second hop is HTTPS to the external instance's Service port 443, with SNI
pinned to the apex via the `ServersTransport` so the wildcard certificate
validates with verification left on. It must not use port 80: the global
`web → websecure` redirect would send the client back to the LAN wildcard and
loop. The direction is load-bearing in the same way — internal → external only,
because the reverse would put internal-only routes in the tunnel origin's
routing table and publish them.

Cost: external apps take one extra in-cluster hop when reached from the LAN,
and `traefik-internal` becomes the single point of failure for all LAN access
(three replicas across three nodes, same as the external instance).

Trust-zone model, blast radius, and the reason the split exists are in
`networking/wifi_and_isolation.md` §4.
