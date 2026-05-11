# cns-deployments

Multi-brand Frappe / ERPNext deployment repository.
Managed by [Dokploy](https://dokploy.com). One VPS per brand.

**Stack:** Frappe v16 · ERPNext · HRMS · CRM

---

## Repository structure

```
cns-deployments/
├── Dockerfile                          # Shared image — all brands
├── apps.json                           # Apps baked into the image
├── .gitignore
├── README.md                           # This file
│
├── images/
│   └── frappe/
│       ├── Dockerfile                  # Multi-stage build (Python 3.14, Node 24)
│       └── entrypoints/
│           └── nginx-entrypoint.sh
│
├── .github/
│   └── workflows/
│       ├── build-image.yml             # Builds & pushes image on push/tag
│       └── (validate.yml embedded in build-image.yml)
│
├── scripts/                            # Deployed to each VPS
│   ├── backup.sh                       # Back up + optional rclone push
│   ├── restore.sh                      # Restore from SQL dump
│   └── bench.sh                        # Wrapper for bench commands
│
├── runbooks/                           # Brand-agnostic procedures
│   ├── upgrade.md
│   └── add-brand.md
│
└── brands/                             # One directory per brand
    ├── brazenhalo/
    │   ├── docker-compose.yml          # Full self-contained stack
    │   ├── .env.example                # Brand-specific env template
    │   └── README.md                   # VPS, domain, Dokploy app name
    ├── brand2/
    │   ├── docker-compose.yml
    │   ├── .env.example
    │   └── README.md
    └── brand3/
        ├── docker-compose.yml
        ├── .env.example
        └── README.md
```

---

## How it works

### One image, all brands

All brands run the same Frappe apps (ERPNext, HRMS, CRM). A single Docker image
is built by GitHub Actions and pushed to GHCR. Every brand's `docker-compose.yml`
pulls from `ghcr.io/kwaralabs/frappe-cns`.

To update apps or Frappe version:
1. Edit `apps.json` and/or `images/frappe/Dockerfile`
2. Push to `main` → GitHub Actions builds `sha-<hash>` + `latest`
3. Tag a release (`v16.x.x`) → also builds `v16.x.x` tag
4. Update `IMAGE_TAG` in each brand's Dokploy environment → redeploy

### One VPS per brand

Each brand runs on a dedicated VPS with its own Dokploy instance. There are no
port conflicts and no shared infrastructure between brands.

Each VPS's Dokploy connects to this same repo but uses a different compose path:

| Brand | Dokploy compose file path |
|-------|--------------------------|
| brazenhalo | `brands/brazenhalo/docker-compose.yml` |
| brand2 | `brands/brand2/docker-compose.yml` |
| brand3 | `brands/brand3/docker-compose.yml` |

### Per-brand isolation

Each brand directory is completely self-contained:
- Its own `docker-compose.yml` (full stack definition, no external includes)
- Its own `.env.example` with brand-specific defaults
- Its own volume name prefix (e.g. `bh-`, `b2-`, `b3-`) for safe future migration
- Its own Dokploy application with its own secret environment variables

---

## Adding a new brand

See `runbooks/add-brand.md` for the full step-by-step.

Short version:
```bash
cp -r brands/brazenhalo brands/newbrand
# Edit docker-compose.yml: update volume prefix (bh- → nb-)
# Edit .env.example: update SITE_NAME, BACKUP_REMOTE_PATH
# Edit README.md: update domain, VPS, Dokploy app name
git add brands/newbrand && git commit -m "feat: add newbrand" && git push
```

Then set up Dokploy on the new VPS pointing at `brands/newbrand/docker-compose.yml`.

---

## Frappe v16 runtime requirements

| Dependency | Required | This stack |
|------------|---------|------------|
| Python | 3.14 | 3.14 ✅ |
| Node.js | 24 | 24 ✅ |
| MariaDB | 11.8 | 11.8 ✅ |
| Redis | 6+ | 7.2 ✅ |
| OS | Ubuntu 24.04+ | Ubuntu 24.04 ✅ |

Source: https://docs.frappe.io/framework/user/en/installation

---

## Operational commands (run on any brand VPS)

```bash
# Container status
docker compose -f brands/<name>/docker-compose.yml ps

# Logs
docker compose -f brands/<name>/docker-compose.yml logs -f backend

# Bench console
./scripts/bench.sh --site erp.<name>.com console

# Backup
./scripts/backup.sh --push --prune

# Restore
./scripts/restore.sh --site erp.<name>.com --sql backups/.../dump.sql.gz
```

---

## Upgrade

See `runbooks/upgrade.md`.

Short version:
1. Update `IMAGE_TAG` in Dokploy → Redeploy
2. Set `MIGRATE=1` → Redeploy
3. Set `MIGRATE=0` → Redeploy
