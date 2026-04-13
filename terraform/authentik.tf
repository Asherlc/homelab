# Data sources for flows
data "authentik_flow" "default_authorization_flow" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_provider_invalidation_flow" {
  slug = "default-provider-invalidation-flow"
}

# Domain-wide forward auth provider (protects all services via Traefik)
resource "authentik_provider_proxy" "domain_forward_auth" {
  name               = "Forward Auth Provider"
  external_host      = "https://authentik.asherlc.com"
  mode               = "forward_domain"
  authorization_flow = data.authentik_flow.default_authorization_flow.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation_flow.id
  cookie_domain      = var.domain
}

# Single application for domain-wide forward auth
resource "authentik_application" "domain_forward_auth" {
  name              = "Domain Forward Auth"
  slug              = "domain-forward-auth"
  protocol_provider = authentik_provider_proxy.domain_forward_auth.id
}

# Homarr OAuth provider (separate from forward auth)
resource "authentik_provider_oauth2" "homarr" {
  name               = "Homarr OIDC"
  client_id          = "homarr"
  authorization_flow = data.authentik_flow.default_authorization_flow.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation_flow.id
}

# Homarr application
resource "authentik_application" "homarr" {
  name              = "Homarr"
  slug              = "homarr"
  protocol_provider = authentik_provider_oauth2.homarr.id
  meta_launch_url   = "https://homarr.asherlc.com"
  open_in_new_tab   = true
  group             = "Home"
}

# Calibre Web LDAP provider
data "authentik_flow" "default_authentication_flow" {
  slug = "default-authentication-flow"
}

resource "authentik_provider_ldap" "calibre" {
  name         = "Calibre Web LDAP"
  base_dn      = "dc=ldap,dc=goauthentik,dc=io"
  bind_flow    = data.authentik_flow.default_authentication_flow.id
  unbind_flow  = data.authentik_flow.default_provider_invalidation_flow.id
  search_mode  = "cached"
}

# Calibre Web application
resource "authentik_application" "calibre" {
  name              = "Calibre Web"
  slug              = "calibre-web"
  protocol_provider = authentik_provider_ldap.calibre.id
  meta_launch_url   = "https://calibre.asherlc.com"
  open_in_new_tab   = true
  group             = "Media"
}

# LDAP Outpost for Calibre Web
resource "authentik_outpost" "ldap" {
  name               = "LDAP Outpost"
  type               = "ldap"
  service_connection = authentik_service_connection_docker.local.id
  protocol_providers = [
    authentik_provider_ldap.calibre.id
  ]

  config = jsonencode({
    log_level                      = "info"
    docker_network                 = null
    docker_map_ports               = true
    docker_labels                  = null
    container_image                = null
    kubernetes_replicas            = 1
    kubernetes_namespace           = "authentik"
    kubernetes_ingress_annotations = {}
    kubernetes_ingress_secret_name = "authentik-outpost-tls"
    kubernetes_service_type        = "ClusterIP"
    kubernetes_disabled_components = []
    kubernetes_image_pull_secrets  = []
  })
}

# Docker service connection for outpost
resource "authentik_service_connection_docker" "local" {
  name  = "Local Docker"
  local = true
}

# Groups with user memberships
# User IDs: asherlc=5, ellis=6, akadmin=4
resource "authentik_group" "admins" {
  name         = "authentik Admins"
  is_superuser = true
  users        = [4, 5]  # akadmin, asherlc
}

resource "authentik_group" "readonly" {
  name         = "authentik Read-only"
  is_superuser = false
  users        = []
}

resource "authentik_group" "media_users" {
  name  = "Media Users"
  users = [5, 6]  # asherlc, ellis - can access media services
}

resource "authentik_group" "home_users" {
  name  = "Home Users"
  users = [5]  # Only asherlc - can access home services (Ellis excluded from video/scrypted)
}

resource "authentik_group" "restricted_access" {
  name  = "Restricted Services Access"
  users = [5]  # Only asherlc - can access zigbee (Ellis excluded)
}

# Synology DSM OIDC provider

resource "authentik_provider_oauth2" "synology_dsm" {
  name               = "Synology DSM"
  client_id          = "synology-dsm"
  authorization_flow = data.authentik_flow.default_authorization_flow.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation_flow.id
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://nas.asherlc.com/webman/ssoclient/token_relay.html"
    }
  ]
  signing_key        = "e5317336-3e7a-4742-8e8c-cda6efdf35a9"
  property_mappings  = [
    "b6900f1a-0e32-4e5c-a31a-cced7f0f77d0",
    "34235530-e555-4380-800c-36a9c5181eeb",
    "c1f1342d-709b-4b17-8925-fdddf7109e45",
  ]
}

# Synology DSM application
resource "authentik_application" "synology_dsm" {
  name              = "Synology DSM"
  slug              = "dsm"
  protocol_provider = authentik_provider_oauth2.synology_dsm.id
  meta_launch_url   = "https://nas.asherlc.com"
  open_in_new_tab   = true
  group             = "Home"
}

# Dofek OIDC provider (app-level authentication)
resource "authentik_provider_oauth2" "dofek" {
  name               = "Dofek OIDC"
  client_id          = "dofek"
  client_type        = "confidential"
  authorization_flow = data.authentik_flow.default_authorization_flow.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation_flow.id
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://dofek.asherlc.com/auth/callback/authentik"
    }
  ]
  property_mappings = [
    "b6900f1a-0e32-4e5c-a31a-cced7f0f77d0",
    "34235530-e555-4380-800c-36a9c5181eeb",
    "c1f1342d-709b-4b17-8925-fdddf7109e45",
  ]
}

resource "authentik_application" "dofek" {
  name              = "Dofek"
  slug              = "dofek"
  protocol_provider = authentik_provider_oauth2.dofek.id
  meta_launch_url   = "https://dofek.asherlc.com"
  open_in_new_tab   = true
  group             = "Home"
}

# Portainer OIDC provider (homelab Docker management)
resource "authentik_provider_oauth2" "portainer" {
  name               = "Portainer OIDC"
  client_id          = "portainer"
  client_type        = "confidential"
  authorization_flow = data.authentik_flow.default_authorization_flow.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation_flow.id
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://portainer.asherlc.com"
    }
  ]
  property_mappings = [
    "b6900f1a-0e32-4e5c-a31a-cced7f0f77d0",
    "34235530-e555-4380-800c-36a9c5181eeb",
    "c1f1342d-709b-4b17-8925-fdddf7109e45",
  ]
}

resource "authentik_application" "portainer" {
  name              = "Portainer"
  slug              = "portainer"
  protocol_provider = authentik_provider_oauth2.portainer.id
  meta_launch_url   = "https://portainer.asherlc.com"
  open_in_new_tab   = true
  group             = "Home"
}
