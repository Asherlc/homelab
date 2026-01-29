# Git-Crypt Usage Guide

## What is git-crypt?

Git-crypt enables transparent encryption and decryption of files in a git repository. Files you choose to protect are encrypted when committed, and decrypted when checked out. This lets you store secrets directly in your repository securely.

## How It Works

1. **You mark files for encryption** in `.gitattributes`
2. **Files are encrypted automatically** when you commit
3. **Files appear as binary/encrypted** on GitHub
4. **Files are decrypted automatically** on your local machine (when unlocked)

## Files That Are Encrypted

In this repository, these files are automatically encrypted:

```
configarr/secrets.yml              # Configarr API keys
configs/cloudflared/*.json         # Cloudflare tunnel credentials
**/*-key.pem                       # SSL private keys
**/privkey.pem                     # SSL private keys
**/.env                            # Environment variables
**/*.key                           # Any .key files
**/passwords.txt                   # Password files
**/credentials.json                # Credential files
```

## The Encryption Key

**Location:** `~/.homelab-secure/homelab-git-crypt.key`

**⚠️ CRITICAL:** This key is required to decrypt your secrets. Without it, your encrypted files are unrecoverable!

### Backup Your Key

**Immediately after setup, backup the key to:**

1. **Password Manager** (Recommended)
   ```bash
   # Display key for copying
   cat ~/.homelab-secure/homelab-git-crypt.key | base64
   # Save to 1Password/Bitwarden as a secure note
   ```

2. **Encrypted USB Drive**
   ```bash
   cp ~/.homelab-secure/homelab-git-crypt.key /media/usb/homelab-backup/
   ```

3. **Secure Cloud Storage**
   ```bash
   # Encrypt before uploading
   gpg -c ~/.homelab-secure/homelab-git-crypt.key
   # Upload homelab-git-crypt.key.gpg to cloud
   ```

## Common Operations

### Check Encryption Status

See which files are encrypted:

```bash
cd /opt/homelab-config
git-crypt status
```

Output example:
```
encrypted: configarr/secrets.yml
encrypted: configs/cloudflared/credentials.json
not encrypted: docker/compose.yml
not encrypted: README.md
```

### Check if Repository is Unlocked

```bash
cd /opt/homelab-config
git-crypt status -e
```

If unlocked: `unlocked`
If locked: `not encrypted`

### Manually Lock the Repository

This encrypts all files (useful before sharing the directory):

```bash
cd /opt/homelab-config
git-crypt lock
```

Files will now appear encrypted in your working directory.

### Manually Unlock the Repository

```bash
cd /opt/homelab-config
git-crypt unlock ~/.homelab-secure/homelab-git-crypt.key
```

Files are now decrypted in your working directory.

**Note:** The post-merge and post-checkout hooks do this automatically!

## Setting Up on a New Machine

When you clone the repository on a new machine:

1. **Install git-crypt:**
   ```bash
   sudo apt-get install git-crypt
   ```

2. **Clone the repository:**
   ```bash
   git clone git@github.com:Asherlc/homelab.git /opt/homelab-config
   cd /opt/homelab-config
   ```

3. **Copy the encryption key to the new machine:**
   ```bash
   # From password manager, USB drive, or secure transfer
   mkdir -p ~/.homelab-secure
   # Copy key file here
   chmod 600 ~/.homelab-secure/homelab-git-crypt.key
   ```

4. **Unlock the repository:**
   ```bash
   git-crypt unlock ~/.homelab-secure/homelab-git-crypt.key
   ```

5. **Verify decryption:**
   ```bash
   cat configarr/secrets.yml
   # You should see plaintext, not encrypted binary
   ```

## Verifying Encryption

### View Encrypted Files on GitHub

1. Go to: https://github.com/Asherlc/homelab
2. Navigate to `configarr/secrets.yml`
3. You should see binary/encrypted content, NOT plaintext API keys

### Check Local Encryption

```bash
# View file as it appears in git (encrypted)
git show HEAD:configarr/secrets.yml | head -20
# Should show binary/encrypted data

# View file in working directory (decrypted)
cat configarr/secrets.yml
# Should show plaintext secrets
```

## Adding New Files to Encryption

To encrypt a new type of file:

1. **Edit `.gitattributes`:**
   ```bash
   cd /opt/homelab-config
   nano .gitattributes
   ```

2. **Add pattern:**
   ```
   **/new-secret-file.conf filter=git-crypt diff=git-crypt
   ```

3. **Commit and push:**
   ```bash
   git add .gitattributes
   git commit -m "Encrypt new-secret-file.conf"
   git push
   ```

**Note:** Existing files matching the pattern need to be re-added:

```bash
# Remove from git cache
git rm --cached **/new-secret-file.conf

# Re-add (will now be encrypted)
git add **/new-secret-file.conf
git commit -m "Start encrypting new-secret-file.conf"
```

## Removing Files from Encryption

To stop encrypting a file:

1. **Remove from `.gitattributes`:**
   ```bash
   nano .gitattributes
   # Delete or comment out the line
   ```

2. **Re-add the file:**
   ```bash
   git add .gitattributes
   git rm --cached path/to/file
   git add path/to/file
   git commit -m "Stop encrypting file"
   ```

## Sharing Access with Team Members

### Option 1: Share the Symmetric Key (Current Setup)

**Pros:** Simple, single key for everyone
**Cons:** If one person loses access, everyone needs new keys

```bash
# Securely send ~/.homelab-secure/homelab-git-crypt.key
# to the team member via encrypted channel
```

### Option 2: Add GPG Keys (More Secure)

**Pros:** Each person has their own key, revocable
**Cons:** More complex setup

```bash
# Add a collaborator's GPG key
git-crypt add-gpg-user USER_ID

# They can now unlock with their GPG key
git-crypt unlock
```

## Troubleshooting

### "git-crypt: command not found"

Install git-crypt:
```bash
sudo apt-get update
sudo apt-get install git-crypt
```

### Files Show as Encrypted After Unlock

The working directory wasn't refreshed:

```bash
cd /opt/homelab-config
git-crypt unlock ~/.homelab-secure/homelab-git-crypt.key
git checkout .
```

### Lost Encryption Key

**If you have a backup:**
```bash
# Restore from backup
cp /backup/location/homelab-git-crypt.key ~/.homelab-secure/
chmod 600 ~/.homelab-secure/homelab-git-crypt.key
git-crypt unlock ~/.homelab-secure/homelab-git-crypt.key
```

**If you lost the key permanently:**
- Encrypted files are **unrecoverable** from git
- You'll need to:
  1. Manually recreate secrets from current running system
  2. Re-initialize git-crypt with new key
  3. Re-encrypt and force push

### Accidentally Committed Unencrypted Secrets

**DON'T just delete and recommit** - secrets remain in git history!

1. **Stop immediately, don't push if you haven't already**

2. **Remove from history:**
   ```bash
   # Use BFG Repo-Cleaner
   bfg --delete-files secrets.yml
   git reflog expire --expire=now --all
   git gc --prune=now --aggressive
   ```

3. **Force push:**
   ```bash
   git push --force
   ```

4. **Rotate the compromised secrets immediately**

### Merge Conflicts with Encrypted Files

Git-crypt can't auto-merge encrypted files:

```bash
# Accept one version
git checkout --theirs configarr/secrets.yml
# or
git checkout --ours configarr/secrets.yml

# Mark as resolved
git add configarr/secrets.yml
git commit
```

## Best Practices

### ✅ Do

- **Backup your encryption key** in multiple secure locations
- **Test decryption** on a new machine periodically
- **Verify files are encrypted** on GitHub after pushing
- **Use .gitattributes** to explicitly mark sensitive files
- **Document** which files contain secrets

### ❌ Don't

- **Don't commit keys to git** (even encrypted)
- **Don't share keys** via insecure channels (email, Slack, etc.)
- **Don't assume encryption** - always verify with `git-crypt status`
- **Don't forget to unlock** after cloning
- **Don't lose your encryption key** - it's not recoverable

## Security Considerations

### What git-crypt Does

✅ Encrypts file contents in git repository
✅ Protects secrets on GitHub/remote
✅ Allows version control of sensitive configs
✅ Transparent encryption/decryption

### What git-crypt Doesn't Do

❌ Doesn't encrypt filenames
❌ Doesn't encrypt git metadata (commit messages, author, dates)
❌ Doesn't protect against compromised local machine
❌ Doesn't encrypt files in working directory (when unlocked)

### Additional Security

Consider:

1. **File System Encryption** for the local `/opt/homelab-config` directory
2. **GPG keys** instead of symmetric key for team access
3. **Audit logs** for who accesses the encryption key
4. **Regular key rotation** (requires re-encrypting all files)

## Reference

### Common Commands

```bash
# Check status
git-crypt status

# Check if unlocked
git-crypt status -e

# Lock repository
git-crypt lock

# Unlock repository
git-crypt unlock ~/.homelab-secure/homelab-git-crypt.key

# Export key
git-crypt export-key ~/backup/homelab-key

# Show encrypted files
git-crypt status | grep encrypted
```

### File Locations

- **Encryption key:** `~/.homelab-secure/homelab-git-crypt.key`
- **Encryption config:** `/opt/homelab-config/.gitattributes`
- **Repository:** `/opt/homelab-config/`

### Documentation

- **Official git-crypt docs:** https://github.com/AGWA/git-crypt
- **Git attributes:** https://git-scm.com/docs/gitattributes

---

**Questions or Issues?**

See troubleshooting section above or check:
- Git-crypt status: `git-crypt status`
- Git-crypt issues: https://github.com/AGWA/git-crypt/issues
