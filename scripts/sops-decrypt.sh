#!/bin/bash
# Decrypt SOPS files for local viewing/editing
# Usage: ./scripts/sops-decrypt.sh [file]

export SOPS_AGE_KEY_FILE=~/.sops/key.txt

if [ -n "$1" ]; then
    # Decrypt single file in place
    echo "Decrypting $1..."
    sops -d -i "$1"
else
    # Decrypt all SOPS-managed files
    echo "Decrypting all SOPS-managed files..."
    
    for file in configs/overseerr/settings.json \
                configs/bazarr/config.yaml \
                configs/homarr/*.json \
                configarr/secrets.yml \
                configs/cloudflared/credentials.json \
                configs/homebridge/config.json; do
        
        if [ -f "$file" ]; then
            if grep -q "sops:" "$file" || grep -q "ENC\[" "$file"; then
                echo "  Decrypting $file..."
                sops -d -i "$file" 2>/dev/null || echo "    Failed"
            fi
        fi
    done
fi

echo "Done!"
