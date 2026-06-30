# lablumen-k8s

GitOps repository for the LabLumen platform. This is the single source of truth for what runs in the `lablumen-eks` Kubernetes cluster. ArgoCD watches this repository and automatically reconciles the cluster to match its contents.

No application code or business logic lives here — only deployment configuration.

---

## How It Works

Deployments are driven by ArgoCD using the **App-of-Apps** pattern:

1. A single `kubectl apply -f bootstrap/root-app.yaml` bootstraps ArgoCD.
2. The root Application watches this repository and creates all other Applications in a controlled order using sync waves:
   - **Wave 0** — Platform add-ons: ArgoCD, Karpenter, External Secrets Operator, AWS Load Balancer Controller, ExternalDNS, Metrics Server, Prometheus/Grafana.
   - **Wave 1** — Cluster-wide config: External Secrets ClusterSecretStores.
   - **Wave 2** — Application services: all microservices and Redis in both dev and prod namespaces.

Changes to this repository are the only way to change what runs in the cluster. There is no manual `kubectl apply` in day-to-day operations.

---

## Repository Layout

```
bootstrap/
  root-app.yaml                    The single manifest that bootstraps the entire cluster

argocd/
  projects/
    lablumen.yaml                  AppProject — allowed repos, namespaces, and resource types
  apps/
    platform-config.yaml           Application for the ESO ClusterSecretStore resources
    karpenter-nodepool.yaml        Application for Karpenter EC2NodeClass and NodePool
    monitoring-secret.yaml         ExternalSecret syncing Grafana admin credentials
  applicationsets/
    services-dev.yaml              Generates Applications for all services in lablumen-dev
    services-prod.yaml             Generates Applications for all services in lablumen

charts/
  microservice/                    Shared Helm chart used by all stateless services
  redis/                           Ephemeral in-cluster Redis (no persistence)

global-values.yaml                 Shared values applied to every service (image registry host, etc.)

services/
  appointment-service/
    values.yaml                    Service identity, ingress path, SSM config mappings
    values-dev.yaml                Dev image tag — updated by CI on every merge to main
    values-prod.yaml               Prod image tag — updated by CI on every GitHub Release
  report-service/                  (same structure)
  notification-service/            (same structure)
  frontend/                        (same structure)
  redis/                           (same structure)

platform/
  addons/                          ArgoCD Applications for each platform add-on (Helm chart references)
  config/
    cluster-secret-store.yaml      ESO ClusterSecretStores for Secrets Manager and SSM
  karpenter/
    ec2nodeclass.yaml              EC2 image, subnet tags, and security group selectors for new nodes
    nodepool.yaml                  Karpenter NodePool — instance types, vCPU limits, consolidation policy
  monitoring/
    grafana-admin.externalsecret.yaml

scripts/
  bootstrap-argocd.sh              Installs ArgoCD via Helm and applies the root app (run once)
```

---

## Environments

| Environment | Namespace | Image Tag Source |
|---|---|---|
| Dev | `lablumen-dev` | 7-character git SHA, written by CI on every merge to `main` |
| Production | `lablumen` | Semver tag (e.g., `v1.2.0`), written by CI on every GitHub Release |

Both environments run on the same `lablumen-eks` cluster. Promotion is always via Git — never by mutating the cluster directly.

---

## The Microservice Helm Chart

All stateless services share a single reusable chart (`charts/microservice`). It generates the full set of Kubernetes objects for each service:

| Object | Purpose |
|---|---|
| `Deployment` | Pod spec with security context, liveness/readiness probes, resource limits |
| `Service` | Stable ClusterIP DNS name for inter-service communication |
| `Ingress` | ALB path routing rules (managed by AWS Load Balancer Controller) |
| `HPA` | Horizontal Pod Autoscaler — scales replicas based on CPU/memory |
| `PDB` | PodDisruptionBudget — ensures minimum replicas during node maintenance |
| `ExternalSecret` | Pulls config from SSM Parameter Store and Secrets Manager into a Kubernetes Secret |
| `ServiceAccount` | With optional IRSA annotations for pod-level AWS access |
| `NetworkPolicy` | Restricts allowed traffic at the pod level |

Per-service `values.yaml` files only define what is specific to that service: image repository, ingress path, SSM key mappings, and replica counts.

---

## Secrets and Configuration

No secrets or config values are committed to this repository. Everything is sourced from AWS at runtime by External Secrets Operator:

- **Sensitive values** (e.g., `DATABASE_URL`) are read from AWS Secrets Manager.
- **Non-sensitive config** (e.g., Cognito pool ID, SQS URL, S3 bucket name) is read from SSM Parameter Store under `/lablumen/config/*`.

Each pod consumes its config via `envFrom.secretRef` — the application itself has no AWS SDK dependency for configuration.

---

## Bootstrap

Prerequisites: Terraform applied (EKS cluster exists, namespaces and IRSA ServiceAccounts created, Secrets Manager shells populated with real values by an operator).

```bash
bash scripts/bootstrap-argocd.sh
```

This installs ArgoCD via Helm and applies `bootstrap/root-app.yaml`. ArgoCD then manages everything else automatically.

---

## Local Validation

```bash
# Render and validate a service for production
helm template charts/microservice \
  -f global-values.yaml \
  -f services/appointment-service/values.yaml \
  -f services/appointment-service/values-prod.yaml | kubeconform -strict -ignore-missing-schemas

# Lint the chart with service values
helm lint charts/microservice \
  -f global-values.yaml \
  -f services/appointment-service/values.yaml \
  -f services/appointment-service/values-dev.yaml

# Preview what Applications an ApplicationSet would generate
argocd appset generate argocd/applicationsets/services-prod.yaml
```
