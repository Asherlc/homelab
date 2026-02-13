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
