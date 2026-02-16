# Add a new service by adding one line here, then run: tofu apply

services = {
  # Unprotected services (direct routing, no Authentik)
  overseerr = {
    description    = "Media requests"
    tunnel_enabled = true
    tunnel_backend = "http://overseerr:5055"
    use_traefik    = false
  }
  authentik = {
    description    = "Identity provider"
    tunnel_enabled = true
    tunnel_backend = "http://authentik-server:9000"
    use_traefik    = false
  }

  # Protected services (via Traefik with Authentik)
  radarr = {
    description    = "Movie management"
    tunnel_enabled = true
    use_traefik    = true
  }
  sonarr = {
    description    = "TV management"
    tunnel_enabled = true
    use_traefik    = true
  }
  qbittorrent = {
    description    = "Torrent client"
    tunnel_enabled = true
    use_traefik    = true
  }
  prowlarr = {
    description    = "Indexer manager"
    tunnel_enabled = true
    use_traefik    = true
  }
  dashdot = {
    description    = "Server dashboard"
    tunnel_enabled = true
    use_traefik    = true
  }
  homarr = {
    description    = "Homepage"
    tunnel_enabled = true
    use_traefik    = true
  }
  zigbee2mqtt = {
    description    = "Zigbee device management"
    tunnel_enabled = true
    use_traefik    = true
  }
  zigbee = {
    description    = "Zigbee device management (alias)"
    tunnel_enabled = true
    use_traefik    = true
  }
  scrypted = {
    description    = "Home automation video integration"
    tunnel_enabled = true
    use_traefik    = true
  }

  # Local-only service (no tunnel)
  pihole = {
    description    = "DNS ad-blocker"
    tunnel_enabled = false
  }
}
