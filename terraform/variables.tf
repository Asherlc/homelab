variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS:Edit and Zone:Read permissions"
  type        = string
  sensitive   = true
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
  description = "Map of subdomain -> service config for tunnel routing"
  type = map(object({
    description = string
  }))
}
