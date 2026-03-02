# Add a new service by adding one line here, then run: tofu apply

services = {
  # Identity & Access
  authentik = {
    description     = "Identity provider"
    type            = "system"
    tunnel_enabled  = true
    require_auth    = false
    backend_url     = "http://authentik-server:9000"
  }

  # Media Services
  seerr = {
    description     = "Media requests (Seerr)"
    type            = "media"
    tunnel_enabled  = true
    require_auth    = false  # Public for requests
    backend_url     = "http://overseerr:5055"
  }
  
  radarr = {
    description     = "Movie management"
    type            = "media"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://radarr:7878"
  }
  
  sonarr = {
    description     = "TV management"
    type            = "media"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://sonarr:8989"
  }
  
  prowlarr = {
    description     = "Indexer manager"
    type            = "media"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://prowlarr:9696"
  }
  
  bazarr = {
    description     = "Subtitle management"
    type            = "media"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://bazarr:6767"
  }
  
  tautulli = {
    description     = "Plex statistics"
    type            = "media"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://tautulli:8181"
  }
  
  qbittorrent = {
    description     = "Torrent client"
    type            = "media"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://qbittorrent:8080"
  }

  # Home Automation Services
  homarr = {
    description     = "Homepage"
    type            = "home"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://homarr:7575"
  }
  
  dashdot = {
    description     = "Server dashboard"
    type            = "home"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://dashdot:3001"
  }
  
  zigbee2mqtt = {
    description     = "Zigbee device management"
    type            = "home"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://zigbee2mqtt:8080"
    restricted      = true  # Only specific users
  }
  
  zigbee = {
    description     = "Zigbee device management (alias)"
    type            = "home"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://zigbee2mqtt:8080"
    restricted      = true
  }
  
  scrypted = {
    description     = "Home automation video integration"
    type            = "home"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://scrypted:10443"
  }

  # Local-only service (no tunnel)
  pihole = {
    description     = "DNS ad-blocker"
    type            = "home"
    tunnel_enabled  = false
    require_auth    = false
    backend_url     = "http://pihole:80"
  }
}
