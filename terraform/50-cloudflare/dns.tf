# Public DNS, tunnel mode only: apex + wildcard CNAME -> the tunnel's
# cfargotunnel.com target. Proxied is mandatory for cfargotunnel targets;
# Cloudflare flattens the apex CNAME. In dnat mode this layer manages no
# public DNS -- the records are manual (A records at the WAN IP, which is
# never committed). Split-horizon for LAN clients is unaffected: Technitium
# resolves the domain to 10.1.11.50/.51 directly (wifi_and_isolation.md).

data "cloudflare_zone" "public" {
  filter = {
    name = local.domain
  }
}

resource "cloudflare_dns_record" "edge" {
  for_each = local.edge_mode == "tunnel" ? toset(["apex", "wildcard"]) : toset([])

  zone_id = data.cloudflare_zone.public.id
  name    = each.key == "apex" ? local.domain : "*.${local.domain}"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1 # required by the v5 provider; 1 = automatic, the only valid value when proxied
}
