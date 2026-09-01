terraform {
  required_version = ">= 1.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2025.12"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "authentik" {
  url   = "http://localhost:9000"
  token = var.authentik_api_token
}

data "cloudflare_zone" "domain" {
  name = var.domain
}

# DNS CNAME records pointing each service subdomain to the tunnel
resource "cloudflare_record" "tunnel_services" {
  for_each = {
    for k, v in var.services : k => v
    if v.tunnel_enabled
  }

  zone_id = data.cloudflare_zone.domain.id
  name    = each.key
  content = "${var.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  comment = "Managed by OpenTofu - ${each.value.description}"
}

# Cloudflare Tunnel configuration
# ALL traffic goes to Traefik (single ingress rule)
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.tunnel_id

  config {
    # Single wildcard rule - ALL traffic to Traefik
    ingress_rule {
      hostname = "*.${var.domain}"
      service  = "http://traefik:80"
    }

    # Catch-all rule (required by Cloudflare)
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# Explicit hostnames preserve each dev server's origin path semantics. Add a map
# entry only after a corresponding Caddy host route exists on the development Mac.
# The named tunnel itself remains local-config managed on that Mac because its
# credentials and ingress configuration must not be stored in this repository.
resource "cloudflare_record" "paseo_dev" {
  for_each = var.paseo_dev_hosts

  zone_id = data.cloudflare_zone.domain.id
  name    = each.key
  content = "${var.paseo_tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  comment = "Managed by OpenTofu - ${each.value.description}"
}
