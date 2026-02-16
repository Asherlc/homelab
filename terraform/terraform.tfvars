# Add a new service by adding one line here, then run: terraform apply

services = {
  overseerr    = { description = "Media requests" }
  authentik    = { description = "Identity provider" }
  radarr       = { description = "Movie management" }
  sonarr       = { description = "TV management" }
  qbittorrent  = { description = "Torrent client" }
  prowlarr     = { description = "Indexer manager" }
  dashdot      = { description = "Server dashboard" }
  homarr       = { description = "Homepage" }
  zigbee2mqtt  = { description = "Zigbee device management" }
  zigbee       = { description = "Zigbee device management (alias)" }
  pihole       = { description = "DNS ad-blocker" }
  scrypted     = { description = "Home automation video integration" }
}
