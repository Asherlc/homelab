"""Compatibility exports; bootstrap imports kit_secrets to avoid stdlib collisions."""
from kit_secrets import atomic_write, create_once, read_credentials, read_private, token
