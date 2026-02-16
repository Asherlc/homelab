terraform {
  required_version = ">= 1.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "cloudflare_zone" "domain" {
  name = var.domain
}

# DNS CNAME records pointing each service subdomain to the tunnel
resource "cloudflare_record" "tunnel_services" {
  for_each = var.services

  zone_id = data.cloudflare_zone.domain.id
  name    = each.key
  content = "${var.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  comment = "Managed by Terraform - ${each.value.description}"
}

# Cloudflare Tunnel configuration (ingress rules)
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.tunnel_id

  config {
    # Unprotected services (direct routing)
    dynamic "ingress_rule" {
      for_each = {
        for k, v in var.services : k => v
        if v.tunnel_enabled && !v.use_traefik
      }
      content {
        hostname = "${ingress_rule.key}.${var.domain}"
        service  = ingress_rule.value.tunnel_backend
      }
    }

    # Protected services (via Traefik with Authentik)
    dynamic "ingress_rule" {
      for_each = {
        for k, v in var.services : k => v
        if v.tunnel_enabled && v.use_traefik
      }
      content {
        hostname = "${ingress_rule.key}.${var.domain}"
        service  = "http://traefik:80"
        origin_request {
          http_host_header   = "${ingress_rule.key}.${var.domain}"
          origin_server_name = "${ingress_rule.key}.${var.domain}"
        }
      }
    }

    # Catch-all rule (required by Cloudflare)
    ingress_rule {
      service = "http_status:404"
    }
  }
}
