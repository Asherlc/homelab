output "dns_records" {
  description = "Created DNS records"
  value = {
    for name, record in cloudflare_record.tunnel_services :
    name => "${name}.${var.domain}"
  }
}

output "paseo_dev_url" {
  description = "Public HTTPS URL for the local-config Paseo development tunnel"
  value       = "https://${var.paseo_dev_tunnel.hostname}.${var.domain}"
}
