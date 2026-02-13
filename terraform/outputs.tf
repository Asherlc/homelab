output "dns_records" {
  description = "Created DNS records"
  value = {
    for name, record in cloudflare_record.tunnel_services :
    name => "${name}.${var.domain}"
  }
}
