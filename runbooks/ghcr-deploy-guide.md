# GHCR Build → Dokploy Deploy
## Step-by-step guide for BrazenHalo ERPNext

---

## Overview

```
Your Repo (Git push)
      ↓
GitHub Actions (.github/workflows/build-image.yml)
      ↓ builds Dockerfile + apps.json
GHCR  ghcr.io/kwaralabs/frappe-base:<tag>
      ↓ Dokploy pulls on deploy
Dokploy (svr-prod-bh-01)
      ↓ docker compose up
Running ERPNext stack
```

---

## Part 1 — GitHub repository setup

### Step 1.1 — Confirm your repo structure

Your `kwaralabs/cns-deployments` repo must contain these files at the
paths the workflow expects:

```
cns-deployments/
├── .github/
│   └── workflows/
│       └── build-image.yml        ← the GitHub Actions workflow
├── brands/
│   └── brazenhalo/
│       └── docker-compose.yml     ← the compose file
├── Dockerfile                     ← at repo ROOT (not inside brands/)
├── apps.json                      ← at repo ROOT
└── ...
```

> IMPORTANT: The workflow reads `apps.json` from the repo root and the
> Dockerfile from the repo root. The compose file lives under
> `brands/brazenhalo/` — Dokploy is already pointed at that path.

### Step 1.2 — Enable GitHub Actions write permissions

1. Go to your repo → **Settings** → **Actions** → **General**
2. Scroll to **Workflow permissions**
3. Select **Read and write permissions**
4. Click **Save**

This allows the workflow to push packages to GHCR using `GITHUB_TOKEN`.
No manual PAT or secret is needed for the build step.

---

## Part 2 — Make the GHCR package visible to Dokploy

You have two options. Pick one.

### Option A — Make the package public (recommended for simplicity)

After the first workflow run creates the package:

1. Go to `github.com/kwaralabs` (the organisation)
2. Click **Packages** tab
3. Click **frappe-base**
4. Click **Package settings** (bottom left)
5. Scroll to **Danger Zone** → **Change visibility**
6. Set to **Public**
7. Confirm

Dokploy can now pull without any credentials.

### Option B — Keep the package private, add credentials to Dokploy

1. Go to `github.com/settings/tokens` (your personal account or a
   dedicated machine account)
2. Click **Generate new token (classic)**
3. Name it: `dokploy-ghcr-pull`
4. Set expiry: **No expiration** (or rotate annually)
5. Select scope: **read:packages** only
6. Click **Generate token** — copy it immediately

Then in Dokploy:
1. Go to **Settings** → **Registries**
2. Click **Add Registry**
3. Fill in:
   - Registry URL: `ghcr.io`
   - Username: your GitHub username or org name
   - Password: the PAT you just created
4. Click **Save**

---

## Part 3 — Trigger the first image build

### Step 3.1 — Push the workflow file to main

If you haven't already, commit and push:

```bash
git add .github/workflows/build-image.yml Dockerfile apps.json
git commit -m "feat: add GitHub Actions image build workflow"
git push origin main
```

The workflow will trigger automatically because `Dockerfile` and
`apps.json` are in the changed paths list.

### Step 3.2 — Watch the build

1. Go to your repo → **Actions** tab
2. Click the **Build and push Frappe base image** workflow
3. Click the running job → **build-and-push**

Expect the first build to take **25–45 minutes**. This is normal —
bench init clones frappe, erpnext, hrms, and crm from GitHub and
compiles all JS/CSS assets.

Subsequent builds reuse the layer cache stored in GHCR and typically
complete in **5–10 minutes**.

### Step 3.3 — Get the image tag

When the build completes, click the last step **Print Dokploy deploy
instruction**. It will show something like:

```
════════════════════════════════════════════════════════
Image built and pushed successfully.

Update IMAGE_TAG in Dokploy environment:
  IMAGE_TAG=dev-v16-a3f9c12b4d

Then redeploy the BrazenHalo application in Dokploy.
════════════════════════════════════════════════════════
```

Copy that tag. You will paste it into Dokploy in the next step.

---

## Part 4 — Configure Dokploy to pull from GHCR

### Step 4.1 — Set environment variables in Dokploy

Go to your Dokploy application (cns-brazenhalo) → **Environment** tab.

Set or confirm these variables:

| Variable | Value |
|---|---|
| `IMAGE_NAME` | `ghcr.io/kwaralabs/frappe-base` |
| `IMAGE_TAG` | the tag from Step 3.3, e.g. `dev-v16-a3f9c12b4d` |
| `PULL_POLICY` | `always` |
| `DB_ROOT_PASSWORD` | a strong random password |
| `ADMIN_PASSWORD` | a strong random password |
| `SITE_NAME` | `erp.brazenhalo.com` |
| `INSTALL_APP_ARGS` | `--install-app erpnext` |
| `ENABLE_DB` | `1` |
| `CONFIGURE` | `1` |
| `REGENERATE_APPS_TXT` | `1` |
| `CREATE_SITE` | `1` |
| `MIGRATE` | `1` |
| `FRAPPE_SITE_NAME_HEADER` | *(leave blank)* |

> All toggles are set to 1 for first boot. They are safe to run
> simultaneously — each service is idempotent.

### Step 4.2 — Set the domain in Dokploy

Go to the application → **Domains** tab:

- Host: `erp.brazenhalo.com`
- Service: `frontend`
- Port: `8080`
- HTTPS: enabled

### Step 4.3 — Deploy

Click **Deploy** in Dokploy. You will see Dokploy:

1. Pull the compose file from Git
2. Pull `ghcr.io/kwaralabs/frappe-base:<tag>` from GHCR
3. Pull `mariadb:10.6` and `redis:6.2-alpine`
4. Start all services

The pull should complete in under 2 minutes. No build happens on the
server.

---

## Part 5 — First boot sequence

Once all containers are running, the one-shot services fire in
parallel. Watch the logs in Dokploy:

**configurator** — writes `common_site_config.json` and exits. Takes
~10 seconds.

**create-site** — waits for configurator to finish, then runs
`bench new-site` and installs apps. Takes 3–8 minutes depending on
database initialisation speed.

**migration** — runs `bench migrate` on the fresh site. Fast on a new
install (~30 seconds).

When `create-site` logs show:
```
erp.brazenhalo.com already exists
```
or the service exits with code 0, the site is ready.

Open `https://erp.brazenhalo.com` in your browser.
Log in with username `Administrator` and the `ADMIN_PASSWORD` you set.

---

## Part 6 — After first boot, disable the one-shot services

Go to Dokploy → **Environment** tab and update:

| Variable | Change to |
|---|---|
| `CONFIGURE` | `0` |
| `REGENERATE_APPS_TXT` | `0` |
| `CREATE_SITE` | `0` |
| `MIGRATE` | `0` |
| `ENABLE_DB` | `1` ← leave at 1 |

Click **Deploy** again. This redeploy is instant — it just restarts
with the toggles off. The running services (backend, frontend,
workers, scheduler) restart with a fresh pull of the same image tag.

---

## Part 7 — Release workflow for future updates

### When you change `apps.json` or `Dockerfile`:

```
1. Push to main
         ↓
2. GitHub Actions builds new image automatically
         ↓
3. Copy the new IMAGE_TAG from the Actions log
         ↓
4. In Dokploy → Environment → update IMAGE_TAG
         ↓
5. Set MIGRATE=1
         ↓
6. Click Deploy
         ↓
7. Once migration completes → set MIGRATE=0 → Deploy again
```

### For a named production release:

Instead of using the auto-generated SHA tag, trigger the workflow
manually:

1. Go to repo → **Actions** → **Build and push Frappe base image**
2. Click **Run workflow**
3. Enter a tag, e.g. `v16.1.0-r1`
4. Click **Run workflow**

Use that exact tag (`v16.1.0-r1`) in Dokploy for TEST, then promote
the same tag to PROD. Never rebuild between environments.

---

## Quick reference — environment toggle states

| State | ENABLE_DB | CONFIGURE | REGEN | CREATE_SITE | MIGRATE |
|---|---|---|---|---|---|
| First deploy | 1 | 1 | 1 | 1 | 1 |
| Normal running | 1 | 0 | 0 | 0 | 0 |
| Image upgrade | 1 | 0 | 0 | 0 | 1 |
| Add/remove apps | 1 | 1 | 1 | 0 | 1 |
| External DB | 0 | 1 | 1 | 1 | 1 |
