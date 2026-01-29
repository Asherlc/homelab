#!/bin/bash
# Edit SOPS-encrypted file
# Usage: ./scripts/sops-edit.sh configs/overseerr/settings.json

export SOPS_AGE_KEY_FILE=~/.sops/key.txt

if [ -z "$1" ]; then
    echo "Usage: $0 <file>"
    exit 1
fi

sops "$1"
