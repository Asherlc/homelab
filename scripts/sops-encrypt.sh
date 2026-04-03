#!/bin/bash
# Encrypt files with SOPS before committing
# Usage: ./scripts/sops-encrypt.sh [file]
# If no file specified, encrypts all SOPS-managed files

export SOPS_AGE_KEY_FILE=~/.sops/key.txt

if [ -n "$1" ]; then
    # Encrypt single file
    echo "Encrypting $1..."
    sops -e -i "$1"
else
    # Encrypt all SOPS-managed files that are decrypted
    echo "Encrypting all SOPS-managed files..."
    
    # Check each file pattern from .sops.yaml
    for file in configs/overseerr/settings.json \
                configs/bazarr/config.yaml \
                configs/homarr/*.json \
                configarr/secrets.yml \
                configs/cloudflared/credentials.json \
                configs/homebridge/config.json; do
        
        if [ -f "$file" ]; then
            # Check if file is encrypted (contains sops metadata)
            if ! grep -q "sops:" "$file" && ! grep -q "ENC\[" "$file"; then
                echo "  Encrypting $file..."
                sops -e -i "$file" 2>/dev/null || echo "    Failed (might not match patterns)"
            fi
        fi
    done
fi

echo "Done!"
