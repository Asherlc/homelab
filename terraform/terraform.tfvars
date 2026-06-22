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
  plex = {
    description     = "Media server"
    type            = "media"
    tunnel_enabled  = true
    require_auth    = false
    backend_url     = "http://172.17.0.1:32400"
  }

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

  calibre = {
    description     = "eBook library manager"
    type            = "media"
    tunnel_enabled  = true
    require_auth    = true
    backend_url     = "http://nas.local:8083"
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

  nas = {
    description    = "Synology NAS DSM"
    type           = "home"
    tunnel_enabled = true
    require_auth   = true
    backend_url    = "http://nas.local:5000"
  }

  frigate = {
    description    = "Frigate NVR"
    type           = "home"
    tunnel_enabled = true
    require_auth   = true
    backend_url    = "http://frigate.home:5000"
  }

  # Health & Wearables
  openwearables = {
    description    = "Wearable health data platform"
    type           = "home"
    tunnel_enabled = true
    require_auth   = false
    backend_url    = "http://openwearables-frontend:3000"
  }

  openwearables-api = {
    description    = "Wearable health data API"
    type           = "home"
    tunnel_enabled = true
    require_auth   = false
    backend_url    = "http://openwearables-backend:8000"
  }


  tdarr = {
    description    = "Media transcoding"
    type           = "media"
    tunnel_enabled = true
    require_auth   = true
    backend_url    = "http://tdarr:8265"
  }

  grafana = {
    description    = "health data dashboards"
    type           = "home"
    tunnel_enabled = true
    require_auth   = true
    backend_url    = "http://grafana:3000"
  }
  
  homebridge = {
    description    = "homekit integration"
    type           = "home"
    tunnel_enabled = true
    require_auth   = true
    backend_url    = "http://homebridge:8581"
  }

  portainer = {
    description    = "Docker management UI"
    type           = "home"
    tunnel_enabled = true
    require_auth   = false  # Portainer handles its own auth via Authentik OAuth
    backend_url    = "http://portainer:9000"
  }
}
