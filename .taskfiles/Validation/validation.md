# Validation Tasks

Tasks for SOPS secret management, kustomize validation, and YAML linting.

**Module:** `validate` (`.taskfiles/Validation/Taskfile.yaml`)

---

## Secret Testing

### `validate:secrets`

Test SOPS secret decryption for all secrets.

**Usage:**
```bash
task validate:secrets
```

**What it does:**
- Attempts to decrypt all `.sops.yaml` files in `kubernetes/main/bootstrap/flux/secrets/`
- Reports success/failure for each file
- Does not output decrypted content

**Output:**
```
Testing kubernetes/main/bootstrap/flux/secrets/age-key.secret.sops.yaml
✅ kubernetes/main/bootstrap/flux/secrets/age-key.secret.sops.yaml
Testing kubernetes/main/bootstrap/flux/secrets/github-deploy-key.secret.sops.yaml
✅ kubernetes/main/bootstrap/flux/secrets/github-deploy-key.secret.sops.yaml
```

---

## Kustomize Validation

### `validate:kustomize`

Validate all kustomize builds without applying.

**Usage:**
```bash
task validate:kustomize
```

**What it validates:**
- `kubernetes/main/infrastructure` - Infrastructure layer
- `kubernetes/main/platform` - Platform layer
- `kubernetes/main/apps` - Apps layer
- `kubernetes/main/flux/config` - Flux configuration

**Output:**
```
🔍 Building infrastructure...
✅ infrastructure
🔍 Building platform...
✅ platform
🔍 Building apps...
✅ apps
🔍 Building flux config...
✅ flux/config
```

**Catches:**
- YAML syntax errors
- Invalid Kubernetes resources
- Missing dependencies
- Kustomization errors

---

## YAML Linting

### `validate:yaml`

Lint all YAML files for syntax and style.

**Usage:**
```bash
task validate:yaml
```

**Requirements:**
- `yamllint` installed

**What it checks:**
- YAML syntax
- Indentation
- Line length
- Trailing spaces
- Document structure

---

## Complete Validation

### `validate:all`

Run all validation checks.

**Usage:**
```bash
task validate:all
```

**Runs:**
1. `validate:secrets`
2. `validate:kustomize`
3. `validate:yaml`

---

## SOPS Encryption/Decryption

### `validate:sops:encrypt`

Encrypt a plaintext file with SOPS.

**Usage:**
```bash
task validate:sops:encrypt INPUT=file.yaml OUTPUT=file.sops.yaml
```

**Parameters:**
- `INPUT` - Path to plaintext YAML file
- `OUTPUT` - Path for encrypted output file

**Example:**
```bash
# Create plaintext secret
cat > /tmp/my-secret.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: default
stringData:
  username: admin
  password: supersecret
EOF

# Encrypt it
task validate:sops:encrypt \
  INPUT=/tmp/my-secret.yaml \
  OUTPUT=kubernetes/main/bootstrap/flux/secrets/my-secret.secret.sops.yaml

# Clean up plaintext
rm /tmp/my-secret.yaml
```

**What it does:**
- Reads age public key from `~/.sops/age.agekey`
- Encrypts only `data` and `stringData` fields
- Saves encrypted file to OUTPUT path

---

### `validate:sops:decrypt`

Decrypt a SOPS encrypted file to plaintext.

**Usage:**
```bash
task validate:sops:decrypt INPUT=file.sops.yaml OUTPUT=file.yaml
```

**Parameters:**
- `INPUT` - Path to encrypted SOPS file
- `OUTPUT` - Path for plaintext output file

**Example:**
```bash
# Decrypt to temp file
task validate:sops:decrypt \
  INPUT=kubernetes/main/bootstrap/flux/secrets/age-key.secret.sops.yaml \
  OUTPUT=/tmp/age-key.yaml

# View it
cat /tmp/age-key.yaml

# Delete plaintext (important!)
rm /tmp/age-key.yaml
```

**⚠️ Warning:** Decrypted files contain sensitive data! Delete after use and never commit to git.

---

### `validate:sops:view`

View decrypted content without saving to disk.

**Usage:**
```bash
task validate:sops:view FILE=file.sops.yaml
```

**Parameters:**
- `FILE` - Path to encrypted SOPS file

**Example:**
```bash
# View GitHub deploy key
task validate:sops:view \
  FILE=kubernetes/main/bootstrap/flux/secrets/github-deploy-key.secret.sops.yaml
```

**Use when:**
- You need to check secret content
- You don't want to create temporary files
- Quick inspection

---

### `validate:sops:edit`

Edit a SOPS encrypted file in-place.

**Usage:**
```bash
task validate:sops:edit FILE=file.sops.yaml
```

**Parameters:**
- `FILE` - Path to encrypted SOPS file

**Example:**
```bash
# Edit cluster secrets
task validate:sops:edit \
  FILE=kubernetes/main/bootstrap/flux/secrets/cluster-secrets.secret.sops.yaml
```

**What it does:**
1. Decrypts file to temporary location
2. Opens in `$EDITOR` (vim, nano, etc.)
3. Re-encrypts on save
4. Cleans up temporary file

---

### `validate:sops:rotate`

Rotate SOPS encryption keys.

**Usage:**
```bash
task validate:sops:rotate FILE=file.sops.yaml
```

**Parameters:**
- `FILE` - Path to encrypted SOPS file

**Example:**
```bash
# Rotate keys for age-key secret
task validate:sops:rotate \
  FILE=kubernetes/main/bootstrap/flux/secrets/age-key.secret.sops.yaml
```

**Use when:**
- You generated a new age key
- You need to re-encrypt with current key
- Key rotation policy requires it

---

## Common Workflows

### Before Committing Changes

```bash
# Validate everything
task validate:all

# If errors, fix and re-validate
task validate:kustomize
```

### Creating a New Secret

```bash
# 1. Create plaintext secret
cat > /tmp/new-secret.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: new-secret
  namespace: flux-system
stringData:
  key: value
EOF

# 2. Encrypt it
task validate:sops:encrypt \
  INPUT=/tmp/new-secret.yaml \
  OUTPUT=kubernetes/main/bootstrap/flux/secrets/new-secret.secret.sops.yaml

# 3. Verify encryption worked
task validate:sops:view \
  FILE=kubernetes/main/bootstrap/flux/secrets/new-secret.secret.sops.yaml

# 4. Clean up plaintext
rm /tmp/new-secret.yaml

# 5. Commit encrypted file
git add kubernetes/main/bootstrap/flux/secrets/new-secret.secret.sops.yaml
git commit -m "feat: add new secret"
```

### Updating an Existing Secret

```bash
# Option 1: Edit in-place (recommended)
task validate:sops:edit \
  FILE=kubernetes/main/bootstrap/flux/secrets/cluster-secrets.secret.sops.yaml

# Option 2: Decrypt, edit, re-encrypt
task validate:sops:decrypt \
  INPUT=kubernetes/main/bootstrap/flux/secrets/cluster-secrets.secret.sops.yaml \
  OUTPUT=/tmp/cluster-secrets.yaml

# Edit the file
vim /tmp/cluster-secrets.yaml

# Re-encrypt
task validate:sops:encrypt \
  INPUT=/tmp/cluster-secrets.yaml \
  OUTPUT=kubernetes/main/bootstrap/flux/secrets/cluster-secrets.secret.sops.yaml

# Clean up
rm /tmp/cluster-secrets.yaml
```

---

## Troubleshooting

### "Failed to get the data key"

**Problem:** SOPS can't decrypt because it doesn't have the age key.

**Solution:**
```bash
# Ensure age key exists
ls -la ~/.sops/age.agekey

# Check SOPS_AGE_KEY_FILE is set
echo $SOPS_AGE_KEY_FILE

# Manually set if needed
export SOPS_AGE_KEY_FILE=~/.sops/age.agekey
```

### "no age key found in file"

**Problem:** The encrypted file doesn't have an age key.

**Solution:**
```bash
# Re-encrypt with your age key
task validate:sops:rotate FILE=<file>
```

### "Input file not found"

**Problem:** Path to input file is wrong.

**Solution:**
```bash
# Use absolute paths or verify relative path
ls -la kubernetes/main/bootstrap/flux/secrets/

# Use tab completion
task validate:sops:view FILE=<tab>
```

---

## Security Best Practices

1. **Never commit plaintext secrets**
   - Always encrypt before committing
   - Add common plaintext filenames to `.gitignore`

2. **Protect your age key**
   - Backup `~/.sops/age.agekey` securely
   - Never commit age key to git
   - Store in password manager

3. **Delete plaintext after use**
   - Decrypted files in `/tmp/` should be deleted immediately
   - Use `validate:sops:view` when possible instead of decrypt

4. **Rotate keys periodically**
   - Generate new age key annually
   - Use `validate:sops:rotate` to update all secrets

---

## Variables Used

| Variable | Value | Description |
|----------|-------|-------------|
| `FLUX_SECRETS` | `kubernetes/main/bootstrap/flux/secrets` | SOPS encrypted secrets directory |
| `CLUSTER_DIR` | `kubernetes/main` | Main cluster directory |

---

## Related Documentation

- [SOPS Documentation](https://github.com/getsops/sops)
- [age Documentation](https://github.com/FiloSottile/age)
- [Kustomize Documentation](https://kustomize.io/)