output "dns_records" {
  description = "Created DNS records"
  value = {
    for name, record in cloudflare_record.tunnel_services :
    name => "${name}.${var.domain}"
  }
}

output "paseo_dev_urls" {
  description = "Public HTTPS URLs for explicitly routed Paseo development servers"
  value = {
    for hostname, record in cloudflare_record.paseo_dev :
    hostname => "https://${record.hostname}"
  }
}
