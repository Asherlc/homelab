#!/bin/bash
# Import existing Authentik resources into OpenTofu

cd /opt/homelab-config/terraform

echo "Importing Authentik resources..."

# Import the provider (ID: 3)
tofu import authentik_provider_proxy.domain_forward_auth 3

# Import applications
tofu import authentik_application.domain_forward_auth 573b6857-4295-4354-9e12-db67428a8ef1
tofu import authentik_application.homarr 1ab46955-f8ab-4986-a44f-43b5db830ee0

# Import groups
tofu import authentik_group.admins c96bc055-b3b7-4486-8e96-1a98bc66400d
tofu import authentik_group.readonly 08f628b4-c0f7-4679-9ca1-154d00541695

echo "Done! Now run 'tofu plan' to verify everything matches."
