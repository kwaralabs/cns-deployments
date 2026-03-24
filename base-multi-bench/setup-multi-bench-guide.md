# Usage Guidance of setup.sh

To use on a freshly reset VPS. As root on the fresh VPS:

```
apt-get update && apt-get install -y curl
```
```
curl -o setup.sh 'https://raw.githubusercontent.com/krl-cns/cns-deployment/refs/heads/main/base-multi-bench/setup-multi-bench.sh'
```
```
chmod +x setup.sh
```
```
./setup.sh
```

The script runs as root, creates the frappe user, installs Docker, builds the image, and deploys everything. It will stop with a clear error message if any critical check fails (wrong domain in YAML, missing env vars, etc.).


# Architecture

The configuration is now a PROJECTS array where each entry defines a complete project:

```
PROJECTS=(
  "project-name|domain|image-tag|extra-apps|apps-json"
)
```

Key design decisions:
- Different app combos → different images. Since apps are baked in at build time, boujeeboyz-one (erpnext only) uses customapp-erp:1.0.0, while boujeeboyz-two (erpnext + hrms) uses customapp-erp-hr:1.0.0. The script deduplicates — if two projects share the same image tag, it only builds once.
- Each project gets its own bench. Own redis, workers, scheduler, frontend. They share only Traefik and MariaDB.
- Each project gets its own admin password. Stored together in ~/passwords/all-credentials.txt.
- Backup crons are staggered. Project 1 backs up at 2:00, project 2 at 2:15, project 3 at 2:30 — so they don't hammer MariaDB simultaneously.
- To add or remove projects, just edit the PROJECTS array. For example, to add a fourth project:

```
"client-four|client4.collabnscale.io|customapp-erp-hr:1.0.0|hrms|[
    {\"url\": \"https://github.com/frappe/erpnext\", \"branch\": \"version-16\"},
    {\"url\": \"https://github.com/frappe/hrms\", \"branch\": \"version-16\"}
  ]"
```

Note this reuses customapp-erp-hr:1.0.0 (same image as project 2), so the script will skip building it again.