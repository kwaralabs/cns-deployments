# Runbook: Image Upgrade

Applies to all brands. Run this on each brand's VPS independently.

## Pre-upgrade checklist

- [ ] Take a full backup: `./scripts/backup.sh --push`
- [ ] Confirm backup files exist and are readable
- [ ] Schedule a maintenance window (migrations enable maintenance mode automatically)
- [ ] Verify the new `IMAGE_TAG` has passed CI/CD and been tested

## Upgrade steps

### 1. Update IMAGE_TAG

In Dokploy → Application → **Environment** tab:

```
IMAGE_TAG=v16.x.x-rN    ← replace with the new tag
```

Click **Save** → **Redeploy**. Containers restart with the new image.

### 2. Run migrations

In Dokploy Environment tab:

```
MIGRATE=1
```

Click **Save** → **Redeploy**.

The `migration` service will:
1. Enable maintenance mode (site shows maintenance page)
2. Run `bench --site all migrate`
3. Disable maintenance mode

Watch logs: `docker compose logs -f migration`

### 3. Disable migration toggle

```
MIGRATE=0
```

Click **Save** → **Redeploy**.

### 4. Verify

- [ ] Site loads at `https://<SITE_NAME>`
- [ ] Admin login works
- [ ] ERPNext / HRMS / CRM modules are accessible
- [ ] No errors in `docker compose logs backend`

## Rollback

If anything goes wrong after migration, roll back the image:

```
IMAGE_TAG=<previous-tag>   ← restore in Dokploy Environment tab
```

Redeploy. Note: DB migrations are generally not reversible — the pre-upgrade backup is your safety net.
