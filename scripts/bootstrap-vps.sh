#!/usr/bin/env bash
set -euo pipefail

#
# Bootstrap script for deploying Aggro to a fresh Ubuntu VPS with K3s.
#
# Usage:
#   export DOMAIN="app.yourdomain.com"
#   export ACME_EMAIL="you@email.com"
#   export GHCR_TOKEN="ghp_..."            # GitHub PAT with read:packages scope
#   export PG_PASSWORD="changeme"
#   export MINIO_ACCESS_KEY="changeme"
#   export MINIO_SECRET_KEY="changeme"
#   export KEYCLOAK_ADMIN_PASSWORD="changeme"
#   export KEYCLOAK_USER_PASSWORD="changeme"
#   export GEE_SERVICE_ACCOUNT="sa@project.iam.gserviceaccount.com"
#   export GEE_PROJECT="your-gee-project"
#   bash scripts/bootstrap-vps.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

for var in DOMAIN ACME_EMAIL GHCR_TOKEN PG_PASSWORD MINIO_ACCESS_KEY MINIO_SECRET_KEY \
           KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_USER_PASSWORD GEE_SERVICE_ACCOUNT GEE_PROJECT; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set"
    exit 1
  fi
done

echo "=== Installing K3s ==="
if ! command -v k3s &>/dev/null; then
  curl -sfL https://get.k3s.io | sh -
  echo "Waiting for K3s to be ready..."
  sleep 10
  until sudo k3s kubectl get nodes | grep -q " Ready"; do sleep 2; done
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== Installing cert-manager ==="
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
echo "Waiting for cert-manager..."
kubectl -n cert-manager wait --for=condition=available --timeout=120s deployment/cert-manager
kubectl -n cert-manager wait --for=condition=available --timeout=120s deployment/cert-manager-webhook

echo "=== Creating namespace ==="
kubectl apply -f "$REPO_DIR/k8s/namespace.yaml"

echo "=== Creating ghcr.io pull secret ==="
kubectl -n aggro create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=agggroanalytics \
  --docker-password="$GHCR_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Creating secrets ==="
kubectl -n aggro create secret generic postgres-credentials \
  --from-literal=password="$PG_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n aggro create secret generic minio-credentials \
  --from-literal=access-key="$MINIO_ACCESS_KEY" \
  --from-literal=secret-key="$MINIO_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n aggro create secret generic keycloak-credentials \
  --from-literal=admin-password="$KEYCLOAK_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n aggro create secret generic backend-secrets \
  --from-literal=BACKEND_MINIO_ACCESS_KEY="$MINIO_ACCESS_KEY" \
  --from-literal=BACKEND_MINIO_SECRET_KEY="$MINIO_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n aggro create secret generic ingestion-secrets \
  --from-literal=INGESTION_MINIO_ACCESS_KEY="$MINIO_ACCESS_KEY" \
  --from-literal=INGESTION_MINIO_SECRET_KEY="$MINIO_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

declare -A ML_PREFIXES=( ["m1-health-stress"]="M1" ["m2-irrigation-wateruse"]="M2" ["m3-soil-degradation"]="M3" )
for mod in m1-health-stress m2-irrigation-wateruse m3-soil-degradation; do
  p="${ML_PREFIXES[$mod]}"
  kubectl -n aggro create secret generic "${mod}-secrets" \
    --from-literal="${p}_TRAINING_POSTGRES_PASSWORD=$PG_PASSWORD" \
    --from-literal="${p}_TRAINING_MINIO_ACCESS_KEY=$MINIO_ACCESS_KEY" \
    --from-literal="${p}_TRAINING_MINIO_SECRET_KEY=$MINIO_SECRET_KEY" \
    --from-literal="${p}_INFERENCE_POSTGRES_PASSWORD=$PG_PASSWORD" \
    --from-literal="${p}_INFERENCE_MINIO_ACCESS_KEY=$MINIO_ACCESS_KEY" \
    --from-literal="${p}_INFERENCE_MINIO_SECRET_KEY=$MINIO_SECRET_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
done

if [ -f "$REPO_DIR/secrets/gee-sa-key.json" ]; then
  kubectl -n aggro create secret generic gee-sa-key \
    --from-file=gee-sa-key.json="$REPO_DIR/secrets/gee-sa-key.json" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "WARNING: secrets/gee-sa-key.json not found, skipping GEE secret"
fi

echo "=== Substituting placeholders in manifests ==="
WORK_DIR=$(mktemp -d)
cp -r "$REPO_DIR/k8s" "$WORK_DIR/k8s"

PUBLIC_URL="https://${DOMAIN}"
sed -i "s|__DOMAIN__|${DOMAIN}|g" "$WORK_DIR"/k8s/ingress.yaml
sed -i "s|__ACME_EMAIL__|${ACME_EMAIL}|g" "$WORK_DIR"/k8s/cert-manager-issuer.yaml
sed -i "s|__PUBLIC_URL__|${PUBLIC_URL}|g" "$WORK_DIR"/k8s/infra/keycloak.yaml
sed -i "s|__KEYCLOAK_USER_PASSWORD__|${KEYCLOAK_USER_PASSWORD}|g" "$WORK_DIR"/k8s/infra/keycloak.yaml
sed -i "s|__PG_PASSWORD__|${PG_PASSWORD}|g" "$WORK_DIR"/k8s/apps/backend.yaml
sed -i "s|__PG_PASSWORD__|${PG_PASSWORD}|g" "$WORK_DIR"/k8s/apps/ingestion-worker.yaml
sed -i "s|__GEE_SERVICE_ACCOUNT__|${GEE_SERVICE_ACCOUNT}|g" "$WORK_DIR"/k8s/apps/ingestion-worker.yaml
sed -i "s|__GEE_PROJECT__|${GEE_PROJECT}|g" "$WORK_DIR"/k8s/apps/ingestion-worker.yaml

echo "=== Applying cert-manager issuer ==="
kubectl apply -f "$WORK_DIR/k8s/cert-manager-issuer.yaml"

echo "=== Applying all manifests ==="
kubectl apply -k "$WORK_DIR/k8s/"

echo "=== Waiting for infrastructure ==="
kubectl -n aggro wait --for=condition=available --timeout=120s deployment/postgres
kubectl -n aggro wait --for=condition=available --timeout=120s deployment/kafka
kubectl -n aggro wait --for=condition=available --timeout=120s deployment/minio
kubectl -n aggro wait --for=condition=available --timeout=180s deployment/keycloak

echo "=== Running seed-models job ==="
kubectl -n aggro delete job seed-models --ignore-not-found
kubectl -n aggro delete job kafka-init-topics --ignore-not-found
kubectl apply -k "$WORK_DIR/k8s/" --selector="app=seed-models" 2>/dev/null || true

rm -rf "$WORK_DIR"

echo ""
echo "=== Bootstrap complete ==="
echo "Your application will be available at: https://${DOMAIN}"
echo ""
echo "Next steps:"
echo "  1. Point your DNS A record for ${DOMAIN} to this server's IP"
echo "  2. Wait for cert-manager to issue the TLS certificate"
echo "  3. Check status: kubectl -n aggro get pods"
