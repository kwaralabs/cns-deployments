# Runbook: Adding a New Brand

## What you need before starting

- A provisioned VPS with Dokploy installed
- A domain pointed at the VPS IP (DNS A record)
- A Dokploy account connected to `kwaralabs/cns-deployments` on GitHub

## Steps

### 1. Create the brand directory

```bash
# Clone the repo locally
git clone https://github.com/kwaralabs/cns-deployments.git
cd cns-deployments

# Copy the closest existing brand as a template
cp -r brands/brazenhalo brands/newbrand
```

### 2. Update docker-compose.yml

Edit `brands/newbrand/docker-compose.yml`. Find all volume and network names and
replace the `bh-` prefix with a unique prefix for this brand (e.g. `nb-`):

```yaml
# Before
name: bh-db-data
name: bh-bench-network

# After
name: nb-db-data
name: nb-bench-network
```

Update the header comment block with the correct brand name and compose file path.

### 3. Update .env.example

Edit `brands/newbrand/.env.example`:

```env
SITE_NAME=erp.newbrand.com
BACKUP_REMOTE_PATH=cns-backups/newbrand
KEYCLOAK_CLIENT_ID=erp-newbrand
```

Clear all secret values (leave them blank — they'll be set in Dokploy).

### 4. Update README.md

Edit `brands/newbrand/README.md`. Update:
- Brand name
- Domain
- VPS hostname/IP
- Dokploy app name
- Volume prefix

### 5. Commit and push

```bash
git add brands/newbrand
git commit -m "feat: add newbrand deployment stack"
git push origin main
```

### 6. Set up Dokploy on the new VPS

1. Install Dokploy: `curl -sSL https://dokploy.com/install.sh | sh`
2. Create application → Docker Compose
3. Source: GitHub → `kwaralabs/cns-deployments` → `main`
4. Compose file path: `brands/newbrand/docker-compose.yml`
5. Environment tab: paste `.env.example` contents, fill in all secrets
6. Domain tab: `erp.newbrand.com` → port `8080` → HTTPS
7. Authenticate with GHCR (so Dokploy can pull the image):
   ```bash
   echo $GITHUB_PAT | docker login ghcr.io -u <github-user> --password-stdin
   ```

### 7. First deploy

In Dokploy Environment tab, set all toggles:

```
ENABLE_DB=1  CONFIGURE=1  REGENERATE_APPS_TXT=1  CREATE_SITE=1  MIGRATE=1
```

Deploy. Watch logs. After all one-shot services exit with code 0:

```
CONFIGURE=0  REGENERATE_APPS_TXT=0  CREATE_SITE=0  MIGRATE=0
# Leave ENABLE_DB=1
```

Redeploy. Verify site at `https://erp.newbrand.com`.

## Checklist

- [ ] `brands/newbrand/docker-compose.yml` has unique volume/network prefix
- [ ] `brands/newbrand/.env.example` has correct `SITE_NAME` and `BACKUP_REMOTE_PATH`
- [ ] `brands/newbrand/README.md` is updated
- [ ] Changes committed and pushed to `main`
- [ ] Dokploy connected to repo with correct compose path
- [ ] GHCR auth configured on new VPS
- [ ] Secrets set in Dokploy Environment tab
- [ ] Domain DNS resolves to VPS IP
- [ ] First deploy completed successfully
- [ ] Site accessible at HTTPS domain
- [ ] Admin login works
