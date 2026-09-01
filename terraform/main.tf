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

# Paseo's tunnel runs on the development Mac, where its ingress configuration is
# intentionally managed by the local cloudflared YAML file.
resource "cloudflare_zero_trust_tunnel_cloudflared" "paseo_dev" {
  account_id = var.cloudflare_account_id
  name       = var.paseo_dev_tunnel.name
  config_src = "local"
}

# This exact hostname is deliberately separate from the homelab wildcard route.
resource "cloudflare_record" "paseo_dev" {
  zone_id = data.cloudflare_zone.domain.id
  name    = var.paseo_dev_tunnel.hostname
  content = "${var.paseo_dev_tunnel.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  comment = "Managed by OpenTofu - Paseo development tunnel"
}
