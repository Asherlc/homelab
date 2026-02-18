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
