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

variable "services" {
  description = "Map of subdomain -> service config"
  type = map(object({
    description    = string
    tunnel_enabled = bool
    tunnel_backend = optional(string)
    use_traefik    = optional(bool, false)
  }))
}
