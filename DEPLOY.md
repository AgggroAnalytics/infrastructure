# Deployment Guide

## Prerequisites

- A VPS running Ubuntu (22.04+ recommended), at least 4 GB RAM
- A domain name with DNS pointing to the VPS IP
- A GitHub Personal Access Token (PAT) with `read:packages` scope for ghcr.io pulls
- The GEE service account JSON key file

## 1. GitHub Secrets

### Organization-level secret (Settings > Secrets > Actions)

| Secret | Description |
|--------|-------------|
| `DEPLOY_TOKEN` | GitHub PAT with `repo` scope — used by service repos to trigger the deploy workflow in the infrastructure repo |

### Infrastructure repo secrets (Settings > Secrets > Actions)

| Secret | Description |
|--------|-------------|
| `VPS_HOST` | VPS IP address or hostname |
| `VPS_USER` | SSH username (e.g. `root`) |
| `VPS_SSH_KEY` | SSH private key for `VPS_USER` (paste the full key including `-----BEGIN...`) |

No per-service-repo secrets are required. `GITHUB_TOKEN` is automatic and provides `packages:write` for ghcr.io.

## 2. First-time VPS Setup

SSH into your VPS and clone this repo:

```bash
git clone https://github.com/AgggroAnalytics/infrastructure.git /opt/aggro
cd /opt/aggro
```

Place your GEE service account JSON key:

```bash
mkdir -p secrets
# Copy your key file here:
cp /path/to/gee-sa-key.json secrets/gee-sa-key.json
```

Set environment variables and run the bootstrap:

```bash
export DOMAIN="app.yourdomain.com"
export ACME_EMAIL="you@youremail.com"
export GHCR_TOKEN="ghp_xxxxxxxxxxxxx"       # GitHub PAT with read:packages
export PG_PASSWORD="your-postgres-password"
export MINIO_ACCESS_KEY="your-minio-access"
export MINIO_SECRET_KEY="your-minio-secret"
export KEYCLOAK_ADMIN_PASSWORD="your-kc-admin-pw"
export KEYCLOAK_USER_PASSWORD="initial-user-pw"
export GEE_SERVICE_ACCOUNT="sa@project.iam.gserviceaccount.com"
export GEE_PROJECT="your-gee-project-id"

bash scripts/bootstrap-vps.sh
```

This will:
- Install K3s
- Install cert-manager for automatic TLS
- Create all Kubernetes secrets
- Deploy all services

## 3. DNS Setup

Point your domain to the VPS IP address:

```
A record: app.yourdomain.com -> <VPS_IP>
```

cert-manager will automatically obtain a Let's Encrypt TLS certificate once DNS propagates.

## 4. CI/CD Flow

After initial setup, deployments are automatic:

1. Push code to any service repo (`backend`, `frontend`, `ingestion`, `m1-*`, `m2-*`, `m3-*`)
2. GitHub Actions builds the Docker image and pushes to `ghcr.io/agggroanalytics/<service>`
3. The build triggers the `deploy` workflow in this repo
4. The deploy workflow SSHes to the VPS and rolls out the new image

### Manual deployment

To manually trigger a full redeployment:

1. Go to **Actions** in the infrastructure repo
2. Select **Deploy** workflow
3. Click **Run workflow**
4. Leave service empty for full apply, or enter a specific service name

### Rolling back

```bash
# SSH to VPS
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n aggro rollout undo deployment/backend
```

## 5. Monitoring

```bash
# Check all pods
kubectl -n aggro get pods

# Check logs for a service
kubectl -n aggro logs -f deployment/backend

# Check ingress / TLS status
kubectl -n aggro get ingress
kubectl -n aggro get certificate
```

## 6. Architecture

```
Internet
  |
  v
Traefik Ingress (K3s built-in, TLS termination)
  |
  v
Frontend (nginx)
  |-- / -> Vue SPA
  |-- /api/ -> Backend (Go)
  |-- /auth/ -> Keycloak
  |
Backend -> Kafka -> Ingestion Worker -> GEE + ML Services
  |                      |
  v                      v
PostgreSQL             MinIO (artifacts, models, reports)
```
