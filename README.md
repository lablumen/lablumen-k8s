# lablumen-k8s

GitOps repository for the **LabLumen** platform on AWS EKS. It holds the Helm charts, per-environment
value overlays, ArgoCD definitions, and platform add-ons that deploy the LabLumen microservices onto a
Terraform-provisioned `lablumen-eks` cluster.

This repo is **environment-blind and declarative**: it describes *how* to deploy; the per-environment
inputs (image SHA, replicas, hostnames) live in value overlays and are reconciled by ArgoCD.

---

## Repository layout

```
bootstrap/root-app.yaml        App-of-Apps — apply once to bootstrap everything
argocd/
  projects/lablumen.yaml       AppProject (guardrails: repos, namespaces, resource kinds)
  apps/platform-config.yaml    Application → ClusterSecretStores (sync-wave 1)
  applicationsets/
    services-dev.yaml          dev microservices  → namespace lablumen-dev (sync-wave 2)
    services-prod.yaml         prod microservices → namespace lablumen      (sync-wave 2)
charts/
  microservice/                ONE reusable chart for all stateless services
  redis/                       ephemeral in-cluster Redis (no persistence)
global-values.yaml             repo-wide shared values layered under every service — holds global.imageRegistry
services/<svc>/                value overlays only: values.yaml + values-dev.yaml + values-prod.yaml
platform/
  addons/                      ArgoCD Applications for argocd, metrics-server, ESO, ALB ctrl, karpenter (wave 0)
  config/cluster-secret-store.yaml   ESO ClusterSecretStores (Secrets Manager + SSM)
```

## Environments

| Env  | Namespace      | ApplicationSet  | Image tag source                              |
|------|----------------|-----------------|-----------------------------------------------|
| dev  | `lablumen-dev` | `services-dev`  | CI git-write-back of git SHA into `values-dev.yaml` |
| prod | `lablumen`     | `services-prod` | human sets the released SHA in `values-prod.yaml`   |

Both run on the single `lablumen-eks` cluster. Promotion is via Git (edit the prod value file),
never by mutating the cluster directly.

## How a service is assembled (ArgoCD multi-source)

Each generated `Application` combines two sources of the same repo:
1. a `ref: values` source (provides the value files), and
2. the shared chart (`charts/microservice` or `charts/redis`) with
   `valueFiles: [$values/global-values.yaml, $values/services/<svc>/values.yaml, $values/services/<svc>/values-<env>.yaml]`.

Value precedence (low → high): `charts/microservice/values.yaml` → `global-values.yaml`
(registry host) → `services/<svc>/values.yaml` → `services/<svc>/values-<env>.yaml`.

The image reference is assembled as `<global.imageRegistry>/<image.repository>:<image.tag>`, so the
account-specific registry host lives in **one** place (`global-values.yaml`) — set it once from
`terraform output -raw image_registry`. Per-service files carry only the repo path
(`lablumen/<svc>`).

## Secrets & config (External Secrets Operator)

No secrets or config values live in Git. ESO (SA `lablumen-eso`, IRSA) syncs from AWS into a single
Kubernetes **Secret** per service (consumed via `envFrom.secretRef`):
- sensitive `DATABASE_URL` ← Secrets Manager `lablumen/app/database-url`
- non-sensitive config ← SSM Parameter Store hierarchy `/lablumen/config/*` (`dataFrom`)

> Note: per a deliberate decision, non-sensitive config is delivered via a Secret rather than a
> ConfigMap (avoids ESO's alpha "generic targets" feature). See `extras/CLAUDE.md`.

## Bootstrap

Prerequisites: Terraform applied (cluster, namespaces `lablumen` + `external-secrets`, IRSA
ServiceAccounts incl. `lablumen-eso`, empty Secrets Manager shells populated by an operator), and
ArgoCD installed (`helm install argo/argo-cd -n argocd --create-namespace`).

```bash
kubectl apply -f bootstrap/root-app.yaml
```

Sync order is enforced by sync-waves: AppProject (-1) → addons incl. metrics-server + ESO (0) →
ClusterSecretStores (1) → microservices + redis (2).

## Local validation

No cluster needed:

```bash
# Render + schema-validate a service for an environment
helm template charts/microservice \
  -f charts/microservice/values.yaml \
  -f global-values.yaml \
  -f services/appointment-service/values.yaml \
  -f services/appointment-service/values-prod.yaml \
  | kubeconform -strict -ignore-missing-schemas

# Lint (pass global-values for the registry + a service's values — the chart requires .Values.name)
helm lint charts/microservice \
  -f global-values.yaml \
  -f services/appointment-service/values.yaml -f services/appointment-service/values-dev.yaml
helm lint charts/redis -f services/redis/values.yaml

# Preview the Applications an ApplicationSet would generate
argocd appset generate argocd/applicationsets/services-prod.yaml
```

## Operational notes / known follow-ups (in lablumen-terraform)

- `lablumen-dev` namespace + dev IRSA ServiceAccounts (trust subject
  `system:serviceaccount:lablumen-dev:<svc>`) for report/notification dev AWS access.
- ESO ServiceAccount must be named `lablumen-eso` (SA + IRSA trust subject).

See `../extras/CLAUDE.md` for the full architectural contract and decision log.
