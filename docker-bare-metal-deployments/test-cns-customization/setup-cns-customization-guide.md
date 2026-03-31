# Usage Guidance of setup.sh

To use on a freshly reset VPS. As root on the fresh VPS:

```
apt-get update && apt-get install -y curl
```
```
curl -o setup.sh 'https://raw.githubusercontent.com/kwaralabs/cns-deployments/refs/heads/main/docker-based-deployments/test-cns-customization/setup-cns-customization.sh'
```
```
chmod +x setup.sh
```
```
./setup.sh
```

The script runs as root, creates the frappe user, installs Docker, builds the image, and deploys everything. It will stop with a clear error message if any critical check fails (wrong domain in YAML, missing env vars, etc.).

## Architecture

1. APPS_JSON now includes HRMS — both erpnext and hrms are baked into the Docker image at build time.
2. New EXTRA_APPS config variable — set to "hrms". Phase 9 loops through this list and runs bench install-app for each one after the site is created. This makes it easy to add more apps in the future — just add them to both APPS_JSON (for the image) and EXTRA_APPS (for site installation). For example, to also add payments:

```
APPS_JSON='[
  {"url": "https://github.com/frappe/erpnext", "branch": "version-16"},
  {"url": "https://github.com/frappe/hrms", "branch": "version-16"},
  {"url": "https://github.com/frappe/payments", "branch": "version-16"}
]'
EXTRA_APPS="hrms payments"
```

3. bench migrate runs after all apps are installed — ensures database schema is fully up to date before enabling the scheduler.