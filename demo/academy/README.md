# ERPNext + Frappe LMS — Frappe v16 — Dokploy

## Runtime requirements (v16)

| Dependency | Version |
|---|---|
| Python | **3.14** |
| Node.js | **24 LTS** |
| MariaDB | 10.6+ |
| Redis | 7+ |

---

## Repo structure

All files must live in the **same directory** (e.g. `demo/academy/`):

```
demo/academy/
├── docker-compose.yml   ← Dokploy compose path
├── Dockerfile           ← co-located with compose
├── apps.json            ← co-located with compose; copied into image at build time
├── .env.example         ← commit this; fill real values in Dokploy
└── .gitignore
```

> `build: context: .` resolves to the compose file's directory.
> `apps.json` is copied directly with `COPY apps.json /opt/apps.json` —
> **no base64 encoding needed.**

---

## Adding or removing apps

Edit `apps.json`, commit, and push. Dokploy's webhook triggers a rebuild
and the new app list is baked into the image automatically.

```jsonc
[
  { "url": "https://github.com/frappe/erpnext",  "branch": "version-16" },
  { "url": "https://github.com/frappe/payments", "branch": "version-16" },
  { "url": "https://github.com/frappe/lms",      "branch": "main" }
]
```

After the image rebuilds, install new apps on the existing site:

```bash
docker compose -p <project> exec backend \
  bench --site demo.yourdomain.com install-app <app_name>
```

---

## Apps bundled

| App | Branch |
|---|---|
| frappe | version-16 |
| erpnext | version-16 |
| payments | version-16 (erpnext peer dep) |
| lms | main |

---

## One-time Dokploy setup

### 1. Push to GitHub

```bash
git add demo/academy/
git commit -m "chore: frappe v16 demo stack"
git push
```

### 2. Connect Dokploy to the private repo

1. Dokploy → New Project → Docker Compose
2. Source: GitHub → select repo → compose path: `demo/academy/docker-compose.yml`
3. Copy the generated **SSH Deploy Key** → GitHub repo → Settings → Deploy Keys → Add (read-only)

### 3. Set Environment Variables in Dokploy

Go to **Project → Environment Variables** and add all vars from `.env.example`.

**No `APPS_JSON_BASE64` required** — apps.json is read directly from the repo.

**Minimum required vars:**

| Variable | Value |
|---|---|
| `SITE_NAME` | `demo.yourdomain.com` |
| `DB_ROOT_PASSWORD` | strong password |
| `ADMIN_PASSWORD` | strong password |
| `CONFIGURE` | `1` |
| `CREATE_SITE` | `1` |
| `ENABLE_DB` | `1` |

### 4. Configure Dokploy domain

Dokploy → Domains:
- Domain: `demo.yourdomain.com`
- Port: `8080`
- Enable HTTPS (Dokploy's Traefik provisions Let's Encrypt)

### 5. First deploy

Hit **Deploy** in Dokploy (or push a commit — webhook triggers it).

**First build: ~20–30 min** (Python 3.14 + Node 24 + app clones + asset compilation).
Subsequent builds use BuildKit layer cache and are much faster.

### 6. Watch site creation

```bash
docker compose -p <dokploy-project-name> logs -f create-site
```

Wait for exit code 0 — stack is live.

### 7. Login

```
URL:      https://demo.yourdomain.com
User:     Administrator
Password: (your ADMIN_PASSWORD)
```

---

## Lifecycle

| Situation | CONFIGURE | CREATE_SITE | MIGRATE | ENABLE_DB |
|---|---|---|---|---|
| First deploy | `1` | `1` | `0` | `1` |
| Normal redeploy | `0` | `0` | `0` | `1` |
| After image upgrade | `0` | `0` | `1` | `1` |

Change these in Dokploy → Environment Variables, then redeploy.

---

## Useful commands

```bash
# Shell into backend
docker compose -p <project> exec backend bash

# Migrate
docker compose -p <project> exec backend bench --site demo.yourdomain.com migrate

# Clear cache
docker compose -p <project> exec backend bench --site demo.yourdomain.com clear-cache

# Backup
docker compose -p <project> exec backend bench --site demo.yourdomain.com backup --with-files

# Service status
docker compose -p <project> ps
```
