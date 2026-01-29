# SOPS Usage Guide

## What is SOPS?

SOPS (Secrets OPerationS) encrypts specific values in YAML, JSON, and other files while keeping the structure readable. Unlike git-crypt (which encrypts entire files), SOPS lets you see the configuration structure on GitHub while protecting secrets.

## Example

**Before SOPS (git-crypt):**
```
(binary encrypted data - unreadable)
```

**With SOPS:**
```json
{
  "applicationTitle": "Overseerr",
  "apiKey": "ENC[AES256_GCM,data:encrypted...]",
  "port": 32400
}
```
Structure is visible, only secrets are encrypted!

## Setup

**Encryption Key:** `~/.sops/key.txt` on homelab.lan
**Backed up to:** 1Password (search "SOPS Age Key")
**Public key:** `age1cmvfpx67qzk2g8ldw5q8k356msnw0zxjvwg68dxux6475cyy5arsvekytd`

## Configuration

SOPS is configured via `.sops.yaml` which defines:
- Which files to encrypt
- Which keys/fields to encrypt in each file
- Which age key to use

## Working with SOPS Files

### View a SOPS File (Decrypted)

```bash
cd /opt/homelab-config
export SOPS_AGE_KEY_FILE=~/.sops/key.txt
sops -d configs/overseerr/settings.json
```

Or use the helper:
```bash
./scripts/sops-decrypt.sh configs/overseerr/settings.json
cat configs/overseerr/settings.json  # Now decrypted locally
```

### Edit a SOPS File

**Best method:**
```bash
cd /opt/homelab-config
./scripts/sops-edit.sh configs/overseerr/settings.json
```

This opens the file in your editor with values decrypted. When you save, SOPS re-encrypts automatically.

**Manual method:**
```bash
export SOPS_AGE_KEY_FILE=~/.sops/key.txt
sops configs/overseerr/settings.json
```

### Encrypt Files Before Committing

SOPS files must be encrypted before pushing to git:

```bash
cd /opt/homelab-config
./scripts/sops-encrypt.sh  # Encrypts all SOPS-managed files
```

Or for a single file:
```bash
./scripts/sops-encrypt.sh configs/overseerr/settings.json
```

### Decrypt Files After Pulling

```bash
cd /opt/homelab-config
./scripts/sops-decrypt.sh  # Decrypts all SOPS-managed files
```

## Git Workflow

**⚠️ IMPORTANT:** SOPS is NOT automatic like git-crypt!

### Making Changes

1. **Pull latest changes:**
   ```bash
   cd /opt/homelab-config
   git pull
   ```

2. **Decrypt for local work:**
   ```bash
   ./scripts/sops-decrypt.sh
   ```

3. **Make changes:**
   ```bash
   ./scripts/sops-edit.sh configs/overseerr/settings.json
   # Or edit manually then encrypt
   ```

4. **Encrypt before committing:**
   ```bash
   ./scripts/sops-encrypt.sh
   git add -A
   git commit -m "Update Overseerr config"
   git push
   ```

### Viewing Diffs

Git is configured to show decrypted diffs:
```bash
git diff configs/overseerr/settings.json
# Shows decrypted values in the diff!
```

## Files Managed by SOPS

Currently using SOPS for:
- `configs/overseerr/settings.json` - Partial encryption (API keys only)
- `configs/bazarr/config.yaml` - Auth section encrypted
- `configs/homarr/*.json` - API keys encrypted
- `configs/prowlarr/config.xml` - API key encrypted

Still using git-crypt for:
- `configarr/secrets.yml` - Entire file (small, all secrets)
- `configs/cloudflared/credentials.json` - Entire file (all secrets)

## Common Operations

### Add New File to SOPS

1. Edit `.sops.yaml` to add pattern:
   ```yaml
   - path_regex: configs/newservice/config\.yaml$
     encrypted_regex: '^(apiKey|password|secret)$'
     age: age1cmvfpx67qzk2g8ldw5q8k356msnw0zxjvwg68dxux6475cyy5arsvekytd
   ```

2. Encrypt the file:
   ```bash
   sops -e -i configs/newservice/config.yaml
   ```

3. Commit:
   ```bash
   git add configs/newservice/config.yaml .sops.yaml
   git commit -m "Add newservice config with SOPS"
   ```

### Check if File is Encrypted

```bash
grep -q "ENC\[" configs/overseerr/settings.json && echo "Encrypted" || echo "Decrypted"
```

### Re-encrypt with New Key

If you need to rotate keys:
```bash
# Decrypt with old key
SOPS_AGE_KEY_FILE=~/.sops/old-key.txt sops -d -i configs/overseerr/settings.json

# Encrypt with new key  
SOPS_AGE_KEY_FILE=~/.sops/key.txt sops -e -i configs/overseerr/settings.json
```

## Troubleshooting

### "no key could decrypt the data"

Your age key is not accessible:
```bash
# Check key exists
ls -la ~/.sops/key.txt

# Set environment variable
export SOPS_AGE_KEY_FILE=~/.sops/key.txt

# Or retrieve from 1Password
op item get "Homelab SOPS Age Key" --fields notesPlain
```

### "input is not a valid YAML/JSON file"

File might already be encrypted:
```bash
head configs/overseerr/settings.json
# If you see ENC[...], it's encrypted
```

### Accidentally Committed Decrypted Secrets

```bash
# Encrypt it
./scripts/sops-encrypt.sh configs/overseerr/settings.json

# Amend commit
git add configs/overseerr/settings.json
git commit --amend --no-edit
git push --force
```

### File Not Encrypting

Check `.sops.yaml` configuration:
```bash
# Test if file matches pattern
cd /opt/homelab-config
sops -e --config .sops.yaml configs/overseerr/settings.json
```

## Clone on New Machine

1. **Clone repository:**
   ```bash
   git clone git@github.com:Asherlc/homelab.git /opt/homelab-config
   cd /opt/homelab-config
   ```

2. **Install SOPS and age:**
   ```bash
   # Download from releases
   wget https://github.com/getsops/sops/releases/latest/download/sops-...
   wget https://github.com/FiloSottile/age/releases/latest/download/age-...
   ```

3. **Restore age key:**
   ```bash
   mkdir -p ~/.sops
   # Copy from 1Password or secure backup
   echo "AGE-SECRET-KEY-..." > ~/.sops/key.txt
   chmod 600 ~/.sops/key.txt
   ```

4. **Set environment variable:**
   ```bash
   echo 'export SOPS_AGE_KEY_FILE=~/.sops/key.txt' >> ~/.bashrc
   source ~/.bashrc
   ```

5. **Decrypt files for local use:**
   ```bash
   ./scripts/sops-decrypt.sh
   ```

## Comparison: SOPS vs git-crypt

| Feature | SOPS | git-crypt |
|---------|------|-----------|
| **Encryption** | Specific keys/values | Entire file |
| **Readability** | Structure visible on GitHub | Binary blob |
| **Automation** | Manual encrypt/decrypt | Automatic on commit/checkout |
| **Best for** | Config files with mixed content | Files that are all secrets |
| **Complexity** | More complex | Simpler |

## Best Practices

✅ **Do:**
- Use SOPS for configs with mixed secret/non-secret data
- Always encrypt before committing
- Keep age key backed up in 1Password
- Use helper scripts for consistency

❌ **Don't:**
- Don't commit decrypted SOPS files
- Don't lose your age key
- Don't encrypt files that are 100% secrets (use git-crypt instead)
- Don't edit SOPS files manually without sops command

## Resources

- **SOPS GitHub:** https://github.com/getsops/sops
- **age encryption:** https://age-encryption.org/
- **Configuration:** `/opt/homelab-config/.sops.yaml`
- **Helper scripts:** `/opt/homelab-config/scripts/sops-*.sh`

---

**Remember:** SOPS files must be manually encrypted before commit! Use `./scripts/sops-encrypt.sh`
