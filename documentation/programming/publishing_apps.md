# Publishing an App Behind Traefik

The cluster runs two Traefik instances (`terraform/40-kube-networking`, module
`traefik-instance`). An app selects which one carries its traffic — and
therefore whether it is reachable from the internet — by the **ingressClass**
it publishes under. Nothing else in the route changes.

| ingressClass | Instance | LB IP | Reachable from |
|---|---|---|---|
| `traefik-external` | traefik-external | 10.1.11.50 | Internet (WAN DNAT, FW-017) **and** the LAN |
| `traefik-internal` | traefik-internal | 10.1.11.51 | LAN only — never port-forwarded |

`traefik-external` is the internet-facing edge; it is also reachable from the
LAN, so a public app served through it works identically for local development
and for external users (split-horizon DNS resolves the same hostname to the LB
IP on the LAN and to the WAN outside it). `traefik-internal` exists for apps
that must never be exposed to the internet — there is no DNAT to 10.1.11.51, so
the isolation is topological, not a per-route setting.

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

Terraform provisions the edge; the hostname records are added out of band (see
`networking/allocations.md`, Technitium is manual/Ansible):

- **External app** (`traefik-external`): a public record at Cloudflare
  (`my-app.<public domain>` → WAN IP) for internet clients, and an internal
  Technitium record → 10.1.11.50 for LAN clients. The wildcard `*` →
  10.1.11.50 in the internal zone already covers the LAN side.
- **Internal-only app** (`traefik-internal`): an explicit Technitium record
  `my-app.<public domain>` → 10.1.11.51 (more-specific beats the internal
  wildcard). No Cloudflare record — the name does not resolve off-LAN.

Trust-zone model, blast radius, and the reason the split exists are in
`networking/wifi_and_isolation.md` §4.
