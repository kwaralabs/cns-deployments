# Usage Guidance of setup.sh

To use on a freshly reset VPS. As root on the fresh VPS:

```
apt-get update && apt-get install -y curl
```
```
curl -o setup.sh 'https://raw.githubusercontent.com/kwaralabs/cns-deployments/refs/heads/main/docker-based-deployments/base-erpnext-drive/setup-erpnext-drive.sh'
```
```
chmod +x setup.sh
```
```
./setup.sh
```

The script runs as root, creates the frappe user, installs Docker, builds the image, and deploys everything. It will stop with a clear error message if any critical check fails (wrong domain in YAML, missing env vars, etc.).