# Usage Guidance of setup-erpnext.sh

To use on a freshly reset VPS. As root on the fresh VPS:

```
apt-get update && apt-get install -y curl
```
```
curl -o setup-erpnext.sh 'https://raw.githubusercontent.com/krl-cns/cns-deployment/refs/heads/main/demo/setup-multi-bench-demo.sh'
```
```
chmod +x setup-erpnext.sh
```
```
./setup-erpnext.sh
```

The script runs as root, creates the frappe user, installs Docker, builds the image, and deploys everything. It will stop with a clear error message if any critical check fails (wrong domain in YAML, missing env vars, etc.).