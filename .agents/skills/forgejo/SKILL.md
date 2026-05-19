# Skill: Forgejo Admin

Perform administrative operations on the Artemis-Cluster Forgejo instance at `https://git.dcunha.io`.

## Access Methods

Two modes — use the API first; fall back to LXC CLI for operations the API doesn't permit.

### API Access

```bash
# Read admin token from 1Password
FORGEJO_TOKEN=$(op read "op://kubernetes/forgejo/FORGEJO_ADMIN_TOKEN")

# Base URL
FORGEJO_URL="https://git.dcunha.io"

# Example: list repos
curl -s "$FORGEJO_URL/api/v1/repos/search?limit=50&token=$FORGEJO_TOKEN" | jq '.data[].full_name'
```

Store the admin API token in 1Password at `op://kubernetes/forgejo/FORGEJO_ADMIN_TOKEN` (field `FORGEJO_ADMIN_TOKEN` in the `forgejo` item). Generate one if missing — see "Generate Token" below.

### LXC CLI Access

Required for: user creation, token generation, operations the API rejects with 403.

```bash
ssh -i ~/.ssh/id_ed25519_arcana root@10.10.99.104 \
  "pct exec 105 -- su - git -s /bin/bash -c 'forgejo --config /etc/forgejo/app.ini <subcommand>'"
```

---

## Common Operations

### Create a User

```bash
ssh -i ~/.ssh/id_ed25519_arcana root@10.10.99.104 \
  "pct exec 105 -- su - git -s /bin/bash -c \
  'forgejo --config /etc/forgejo/app.ini admin user create \
    --username <name> \
    --email <name>@dcunha.io \
    --password \"$(openssl rand -base64 24)\" \
    --must-change-password=false'"
```

### Generate API Token for a User

```bash
ssh -i ~/.ssh/id_ed25519_arcana root@10.10.99.104 \
  "pct exec 105 -- su - git -s /bin/bash -c \
  'forgejo --config /etc/forgejo/app.ini admin user generate-access-token \
    --username <name> \
    --token-name <purpose> \
    --raw'"
```

The `--raw` flag prints only the token value, no surrounding text.

### Create a Repository

```bash
curl -s -X POST "$FORGEJO_URL/api/v1/user/repos" \
  -H "Authorization: token $FORGEJO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "<repo>",
    "description": "<description>",
    "private": false,
    "auto_init": false
  }'
```

### Add a Collaborator

```bash
curl -s -X PUT "$FORGEJO_URL/api/v1/repos/<owner>/<repo>/collaborators/<username>" \
  -H "Authorization: token $FORGEJO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"permission": "admin"}'
# 204 = success
```

Permissions: `read`, `write`, `admin`.

### Set a Repository Actions Secret

```bash
# Get the public key for encryption first
PUB_KEY=$(curl -s "$FORGEJO_URL/api/v1/repos/<owner>/<repo>/actions/secrets/public-key" \
  -H "Authorization: token $FORGEJO_TOKEN")

# Forgejo v15 accepts plaintext — no encryption needed
curl -s -X PUT "$FORGEJO_URL/api/v1/repos/<owner>/<repo>/actions/secrets/<SECRET_NAME>" \
  -H "Authorization: token $FORGEJO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"data": "<secret-value>"}'
# 201 = created, 204 = updated
```

**RESERVED prefix**: Secret names beginning with `FORGEJO_` are rejected (like `GITHUB_` on GitHub). Use `CI_TOKEN` for Forgejo API tokens.

### Configure a Push Mirror (Forgejo → GitHub)

```bash
curl -s -X POST "$FORGEJO_URL/api/v1/repos/<owner>/<repo>/push_mirrors" \
  -H "Authorization: token $FORGEJO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "remote_name": "github",
    "remote_address": "https://github.com/<owner>/<repo>.git",
    "remote_username": "Exikle",
    "remote_password": "<github-pat>",
    "interval": "8h0m0s",
    "sync_on_commit": true
  }'
```

GitHub PAT: `op read "op://kubernetes/github/GITHUB_PAT"`

Forgejo's `/push_mirrors/sync` API returns 405 in v15. To force a sync, push directly from the bare repo on the LXC:

```bash
ssh -i ~/.ssh/id_ed25519_arcana root@10.10.99.104 \
  "pct exec 105 -- su - git -s /bin/bash -c \
  'git -C /var/lib/forgejo/data/forgejo-repositories/<owner>/<repo>.git \
    push github HEAD:main'"
```

### Check Runner Status

```bash
curl -s "$FORGEJO_URL/api/v1/admin/runners" \
  -H "Authorization: token $FORGEJO_TOKEN" | \
  jq '.runners[] | {name: .name, status: .status, labels: [.labels[].name]}'
```

### Check Workflow Run Status

```bash
curl -s "$FORGEJO_URL/api/v1/repos/<owner>/<repo>/actions/runs?limit=5" \
  -H "Authorization: token $FORGEJO_TOKEN" | \
  jq '.workflow_runs[] | {id: .id, status: .status, event: .event}'
```

### Trigger a Workflow Run

```bash
curl -s -X POST "$FORGEJO_URL/api/v1/repos/<owner>/<repo>/actions/workflows/<workflow-file.yaml>/dispatches" \
  -H "Authorization: token $FORGEJO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"ref": "main"}'
```

---

## Infrastructure Reference

| Detail           | Value                                                      |
| ---------------- | ---------------------------------------------------------- |
| Forgejo URL      | `https://git.dcunha.io`                                    |
| Forgejo LXC      | LXC 105 on `pantheon` (10.10.99.104)                       |
| SSH to Proxmox   | `ssh -i ~/.ssh/id_ed25519_arcana root@10.10.99.104`        |
| Forgejo internal | `http://forgejo.external-endpoints.svc.cluster.local:3000` |
| Admin user       | `exikle`                                                   |
| Bot user         | `duskbot` (forgesync mirror bot)                           |
| Runner name      | `artemis-k8s` (registered in forgejo namespace)            |
| 1Password item   | `forgejo` (vault: `kubernetes`)                            |

---

## Common Issues

- **API returns 403 "user should be site admin"**: The token doesn't have admin scope. Generate a new token with admin scope via LXC CLI, or use a token from the `exikle` admin account.
- **`FORGEJO_` prefix rejected (400)**: Reserved prefix — rename the secret (e.g. `CI_TOKEN`).
- **Push mirror sync returns 405**: Use LXC bare-repo `git push` instead.
- **`loadF3From` fatal on CLI**: Missing `--config /etc/forgejo/app.ini` flag — always pass it explicitly.
- **User creation fails with bad password**: Generate with `openssl rand -base64 24` to avoid special character quoting issues in shell.
- **Forgejo SSH**: host key is at `10.10.99.24:2222` — `ssh-keyscan -p 2222 10.10.99.24 >> ~/.ssh/known_hosts` if not in known_hosts.
