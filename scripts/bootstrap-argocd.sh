#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-time ArgoCD bootstrap for the LabLumen cluster.
#
# Run AFTER:
#   1. terraform apply (cluster + namespaces + IRSA SAs exist), and
#   2. the first images are pushed to ECR + their SHA written into
#      lablumen-k8s/services/<svc>/values-dev.yaml (the app CI does this), and
#   3. the lablumen-k8s repo (with these changes) is pushed to GitHub, and
#   4. the DATABASE_URL secret is populated (see the reminder below).
#
# It installs ArgoCD via Helm, then applies the App-of-Apps root, which deploys
# everything declaratively (addons wave 0 -> ClusterSecretStore wave 1 -> services wave 2).
# Thereafter ArgoCD self-manages (platform/addons/argocd.yaml).
# ---------------------------------------------------------------------------
set -euo pipefail

CLUSTER="${CLUSTER_NAME:-lablumen-eks}"
REGION="${AWS_REGION:-us-east-1}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.6.0}"
ROOT_APP="$(cd "$(dirname "$0")/.." && pwd)/bootstrap/root-app.yaml"

echo "Cluster: $CLUSTER  Region: $REGION"

echo "==> kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

echo "==> install ArgoCD (Helm)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  --set configs.params."server\.insecure"=true \
  --wait

echo "==> apply App-of-Apps root"
kubectl apply -f "$ROOT_APP"

echo
echo "✓ ArgoCD bootstrapped. Next:"
echo "  - Watch sync:   kubectl -n argocd get applications -w"
echo "  - Admin pass:   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
echo "  - UI:           kubectl -n argocd port-forward svc/argocd-server 8080:443   # then https://localhost:8080 (user: admin)"
echo
echo "⚠ REMINDER: ESO can only sync a POPULATED secret. Put the Postgres DSN into Secrets Manager:"
echo "    aws secretsmanager put-secret-value --secret-id lablumen/app/database-url \\"
echo "      --secret-string 'postgresql://lablumen:<PASSWORD>@<rds-endpoint>:5432/lablumen' --region $REGION"
echo "  (<PASSWORD> is in the RDS-managed secret: terraform output rds_master_user_secret_arn)"
