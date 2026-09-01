variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS:Edit and Zone:Read permissions"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
  default     = "8e5b2f62ffe8ebdd48e725d325a6d51e"
}

variable "domain" {
  description = "Base domain name"
  type        = string
  default     = "asherlc.com"
}

variable "tunnel_id" {
  description = "Cloudflare Tunnel ID"
  type        = string
  default     = "2dd6f4cb-7842-47f1-8c49-7e1c2af9aca9"
}

variable "paseo_dev_tunnel" {
  description = "Existing local-config Cloudflare Tunnel for the development Mac's Paseo service proxy"
  type = object({
    id   = string
    name = string
  })
  default = {
    id   = "eb624b63-2af6-4f47-ab9c-dac3228f0515"
    name = "paseo-dev"
  }
}

variable "paseo_dev_tunnel_secret" {
  description = "Existing paseo-dev tunnel secret from the development Mac's cloudflared credentials file"
  type        = string
  sensitive   = true
}

variable "paseo_dev_hosts" {
  description = "Explicit development-server hostnames routed through the paseo-dev tunnel"
  type = map(object({
    description = string
  }))
  default = {
    p61882 = {
      description = "Paseo development server on port 61882"
    }
    p61999 = {
      description = "Paseo development server on port 61999"
    }
  }
}

variable "services" {
  description = "Map of subdomain -> service config"
  type = map(object({
    description     = string
    type            = string  # "media" or "home" or "system"
    tunnel_enabled  = bool
    require_auth    = bool
    backend_url     = optional(string)
    restricted      = optional(bool, false)
  }))
}

variable "authentik_api_token" {
  description = "Authentik API token"
  type        = string
  sensitive   = true
}
