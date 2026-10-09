# Nexvion E-Commerce Platform - GitOps Migration Guide

This document describes the migration from push-based CI/CD to pull-based GitOps using ArgoCD.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         GITOPS ARCHITECTURE                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌─────────┐  │
│  │  Developer   │───▶│   GitHub     │───▶│  GitHub      │───▶│ ArgoCD  │  │
│  │  (Code Push) │    │  (Source)    │    │  Actions     │    │ (Sync)  │  │
│  └──────────────┘    └──────────────┘    │  (Build &    │    └────┬────┘  │
│                                          │   Update      │         │       │
│                                          │   GitOps      │         ▼       │
│                                          │   Config)     │    ┌─────────┐  │
│                                          └──────────────┘    │  EKS    │  │
│                                                                │ Cluster │  │
│                                                         ┌─────▶│ (Prod)  │  │
│                                                         │      └─────────┘  │
│                                                         │      ┌─────────┐  │
│                                                         └─────▶│  EKS    │  │
│                                                                │ (Staging)    │
│                                                         ┌─────▶│         │  │
│                                                         │      └─────────┘  │
│                                                         │      ┌─────────┐  │
│                                                         └─────▶│  EKS    │  │
│                                                                │ (Dev)       │
│                                                         ┌─────▶│         │  │
│                                                         │      └─────────┘  │
│                                                         │                   │
│                                                         └───────────────────┘
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Repository Structure

```
ecommerce-platform/                    # Application source code (this repo)
├── .github/workflows/ci-cd.yml        # CI/CD Pipeline (build, test, scan, update gitops-config)
├── backend/                           # FastAPI backend
├── frontend/                          # Nginx frontend
├── ai/incident-analysis/              # AI analyzer service
├── helm/ecommerce/                    # Helm chart (base)
├── terraform/                         # Infrastructure as Code
├── scripts/                           # Deployment scripts
└── gitops-config/                     # GitOps declarative config (NEW)
    ├── argocd/
    │   ├── applications/              # ArgoCD Application manifests
    │   ├── projects/                  # ArgoCD Project definitions
    │   └── config/                    # ArgoCD ConfigMaps (RBAC, Notifications, Ingress)
    └── overlays/
        ├── base/                      # Base Kustomize (common config)
        ├── dev/                       # Development environment
        ├── staging/                   # Staging environment
        └── prod/                      # Production environment
```

## Key Changes from Push to Pull

| Aspect | Before (Push) | After (Pull - GitOps) |
|--------|---------------|----------------------|
| **Deployment Trigger** | GitHub Actions runs `helm upgrade` | ArgoCD watches Git repo, syncs on commit |
| **Image Tag Updates** | Passed via `--set` in CI | Committed to `gitops-config/overlays/*/kustomization.yaml` |
| **Environment Config** | Helm values files + CLI flags | Kustomize overlays per environment |
| **Secrets** | Passed via CLI env vars | External Secrets Operator + AWS Secrets Manager |
| **Rollback** | `helm rollback` or re-run workflow | `argocd app rollback` or revert Git commit |
| **Drift Detection** | Manual `helm diff` | ArgoCD continuously monitors & auto-heals |
| **Approval** | GitHub Environments | ArgoCD UI/CLI or PR merge for prod |

## Quick Start

### 1. Prerequisites

```bash
# Required tools
kubectl >= 1.28
helm >= 3.12
argocd CLI >= 2.8
kustomize >= 5.4
aws CLI >= 2.0
```

### 2. Bootstrap ArgoCD

```bash
# Run the bootstrap script
./scripts/bootstrap-argocd.sh

# Or manually:
# 1. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Apply GitOps config
kubectl apply -f gitops-config/argocd/config/
kubectl apply -f gitops-config/argocd/projects/
kubectl apply -f gitops-config/argocd/applications/
```

### 3. Configure Secrets

Create secrets in AWS Secrets Manager for each environment:

```bash
# Development
aws secretsmanager create-secret \
    --name nexvion/dev/database \
    --secret-string '{"url": "postgresql+asyncpg://user:pass@host:5432/nexvion"}'

aws secretsmanager create-secret \
    --name nexvion/dev/jwt \
    --secret-string '{"secret": "your-jwt-secret-min-32-chars"}'

aws secretsmanager create-secret \
    --name nexvion/dev/opensearch \
    --secret-string '{"password": "opensearch-password"}'

aws secretsmanager create-secret \
    --name nexvion/dev/openai \
    --secret-string '{"api-key": "sk-..."}'

# Repeat for staging (nexvion/staging/*) and prod (nexvion/prod/*)
```

### 4. Configure GitHub Secrets

Add these secrets to your GitHub repository:

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS access key with EKS/ECR/SecretsManager permissions |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `GITOPS_BOT_TOKEN` | GitHub PAT with `repo` scope for gitops-config repo |
| `SLACK_TOKEN` | Slack Bot token for ArgoCD notifications |

### 5. Update GitOps Config Repo

Update `GITOPS_REPO` in `.github/workflows/ci-cd.yml`:

```yaml
env:
  GITOPS_REPO: your-org/ai-ecommerce-devops-gitops  # Separate repo recommended
```

## Environment Promotion Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Develop   │────▶│  Staging    │────▶│ Production  │
│  (develop)  │     │  (develop)  │     │   (main)    │
└─────────────┘     └─────────────┘     └─────────────┘
      │                   │                   │
      ▼                   ▼                   ▼
Auto-sync             Auto-sync           Manual Sync
                      (via PR)            (PR Approval)
```

### Development (`develop` branch)
- **Trigger**: Push to `develop`
- **Sync**: Automatic (ArgoCD auto-sync enabled)
- **Config**: `gitops-config/overlays/dev/`
- **Namespace**: `nexvion-dev`

### Staging (`develop` branch)
- **Trigger**: Push to `develop` (same as dev)
- **Sync**: Automatic (ArgoCD auto-sync enabled)
- **Config**: `gitops-config/overlays/staging/`
- **Namespace**: `nexvion-staging`

### Production (`main` branch)
- **Trigger**: Push to `main` (via release PR)
- **Sync**: **Manual** (requires PR approval)
- **Config**: `gitops-config/overlays/prod/`
- **Namespace**: `nexvion`

## CI/CD Pipeline Changes

### Before (Push-based)
```yaml
deploy-staging:
  steps:
    - helm upgrade --install nexvion-staging ./helm/ecommerce \
        --namespace nexvion-staging \
        --set frontend.image.tag=${{ github.sha }}
```

### After (GitOps - Pull-based)
```yaml
gitops-update-staging:
  steps:
    - checkout gitops-config repo
    - kustomize edit set image nexvion-frontend=...:${{ github.sha }}
    - git commit -m "chore(staging): update images to ${{ github.sha }}"
    - git push
# ArgoCD automatically syncs within 3 minutes
```

## Common Operations

### Check Application Status
```bash
# List all applications
argocd app list

# Get detailed status
argocd app get nexvion-dev
argocd app get nexvion-staging
argocd app get nexvion-prod
```

### Manual Sync
```bash
# Sync specific app
argocd app sync nexvion-dev --prune

# Sync with dry-run
argocd app sync nexvion-dev --dry-run

# Force sync (override)
argocd app sync nexvion-dev --force
```

### Rollback
```bash
# List history
argocd app history nexvion-dev

# Rollback to specific revision
argocd app rollback nexvion-dev 3
```

### View Diff (Before Sync)
```bash
# Show what would change
argocd app diff nexvion-dev

# Show diff against local gitops-config
argocd app diff nexvion-dev --local gitops-config/overlays/dev
```

### Access ArgoCD UI
```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward for local access
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Then open https://localhost:8080
```

## Secrets Management

### External Secrets Operator (Production)

Secrets are stored in **AWS Secrets Manager** and synced to Kubernetes:

```
AWS Secrets Manager                    Kubernetes
┌─────────────────────┐                ┌─────────────────┐
│ nexvion/prod/       │ ───ESO Sync──▶ │ nexvion-secrets │
│   database          │                │   DATABASE_URL  │
│   jwt               │                │   JWT_SECRET_KEY│
│   opensearch        │                │   OPENSEARCH_*  │
│   openai            │                │   OPENAI_API_KEY│
└─────────────────────┘                └─────────────────┘
```

### Create Production Secrets
```bash
aws secretsmanager create-secret \
    --name nexvion/prod/database \
    --description "Nexvion Production Database URL" \
    --secret-string '{"url": "postgresql+asyncpg://user:pass@host:5432/nexvion"}'

aws secretsmanager create-secret \
    --name nexvion/prod/jwt \
    --description "Nexvion Production JWT Secret" \
    --secret-string '{"secret": "your-super-secure-jwt-secret-32-chars-min"}'
```

### SealedSecrets (Development - Alternative)
For dev environments without AWS Secrets Manager:

```bash
# Install kubeseal
curl -OL https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.25.0/kubeseal-linux-amd64
sudo install kubeseal-linux-amd64 /usr/local/bin/kubeseal

# Seal a secret
cat secret.yaml | kubeseal --format=yaml > sealed-secret.yaml

# Commit sealed-secret.yaml to gitops-config/overlays/dev/
```

## Monitoring & Alerting

### ArgoCD Notifications (Slack)
Configured in `gitops-config/argocd/config/argocd-notifications-cm.yaml`:

- ✅ Sync Succeeded → `#nexvion-deployments`
- ❌ Sync Failed → `#nexvion-alerts` + `#nexvion-deployments`
- 🔄 Sync Running → `#nexvion-deployments`
- ⚠️ Health Degraded → `#nexvion-alerts`

### Drift Detection
ArgoCD continuously monitors for drift:
- **Auto-heal**: Enabled for dev/staging (`selfHeal: true`)
- **Manual intervention**: Required for prod

### Health Checks
```bash
# Check application health
argocd app get nexvion-dev --show-health

# Health statuses:
# - Healthy: All resources running as expected
# - Progressing: Sync in progress or resources starting
# - Degraded: Resources not matching desired state
# - Suspended: Sync paused
```

## Troubleshooting

### Application Stuck in "Progressing"
```bash
# Check operation state
argocd app get nexvion-dev

# Common causes:
# 1. ImagePullBackOff - check ECR permissions
# 2. Pending pods - check node resources
# 3. CRD not installed - install required CRDs
```

### Sync Fails with "Resource Already Exists"
```bash
# Force prune
argocd app sync nexvion-dev --prune --force

# Or delete conflicting resource manually
kubectl delete <resource> -n nexvion-dev
```

### Drift Detected but Not Auto-Healing (Prod)
```bash
# Prod has selfHeal: false - manual sync required
argocd app sync nexvion-prod --prune
```

### External Secrets Not Syncing
```bash
# Check ExternalSecret status
kubectl get externalsecret -n nexvion-prod
kubectl describe externalsecret nexvion-secrets -n nexvion-prod

# Check ClusterSecretStore
kubectl get clustersecretstore aws-secretsmanager

# Check ESO logs
kubectl logs -n external-secrets-system deployment/external-secrets
```

## Migration Checklist

### Pre-Migration
- [ ] Backup current Helm releases: `helm get values nexvion -n nexvion > backup.yaml`
- [ ] Document current image tags per environment
- [ ] Verify AWS Secrets Manager access
- [ ] Create gitops-config repo (separate or same org)
- [ ] Generate GITOPS_BOT_TOKEN with repo scope

### Migration Steps
- [ ] Run `./scripts/bootstrap-argocd.sh`
- [ ] Verify dev/staging auto-sync works
- [ ] Create production secrets in AWS Secrets Manager
- [ ] Update `GITOPS_REPO` in GitHub Actions
- [ ] Add `GITOPS_BOT_TOKEN` to GitHub secrets
- [ ] Push to `develop` branch to test dev/staging sync
- [ ] Create test PR to `main` for prod release flow
- [ ] Verify ArgoCD notifications in Slack
- [ ] Remove `helm upgrade` from old CI/CD (keep for reference)

### Post-Migration
- [ ] Configure SSO/OIDC for ArgoCD (Dex/Keycloak/Cognito)
- [ ] Set up ArgoCD RBAC groups mapping
- [ ] Configure backup for ArgoCD (etcd/argo-cd repo)
- [ ] Document runbooks for team
- [ ] Schedule regular disaster recovery drills

## Rollback Plan

If issues arise during migration:

```bash
# 1. Disable ArgoCD auto-sync
argocd app set nexvion-dev --sync-policy=none
argocd app set nexvion-staging --sync-policy=none

# 2. Re-enable manual Helm deployments temporarily
# Update CI/CD to use helm upgrade again

# 3. Or revert ArgoCD applications
kubectl delete -f gitops-config/argocd/applications/
kubectl delete -f gitops-config/argocd/projects/

# 4. Reinstall with old Helm-based deployment
./scripts/deploy.sh production
```

## File Reference

| File | Purpose |
|------|---------|
| `gitops-config/overlays/base/kustomization.yaml` | Base Kustomize config |
| `gitops-config/overlays/dev/kustomization.yaml` | Dev environment config |
| `gitops-config/overlays/staging/kustomization.yaml` | Staging environment config |
| `gitops-config/overlays/prod/kustomization.yaml` | Production environment config |
| `gitops-config/argocd/projects/nexvion-project.yaml` | ArgoCD Project (RBAC) |
| `gitops-config/argocd/applications/nexvion-dev.yaml` | Dev Application |
| `gitops-config/argocd/applications/nexvion-staging.yaml` | Staging Application |
| `gitops-config/argocd/applications/nexvion-prod.yaml` | Prod Application (manual sync) |
| `gitops-config/argocd/config/argocd-rbac-cm.yaml` | RBAC policies |
| `gitops-config/argocd/config/argocd-cm.yaml` | ArgoCD settings |
| `gitops-config/argocd/config/argocd-notifications-cm.yaml` | Slack notifications |
| `gitops-config/argocd/config/argocd-ingress.yaml` | ArgoCD UI ingress |
| `scripts/bootstrap-argocd.sh` | One-command bootstrap |
| `.github/workflows/ci-cd.yml` | Updated CI/CD pipeline |

## Support

- **ArgoCD Docs**: https://argo-cd.readthedocs.io/
- **Kustomize Docs**: https://kustomize.io/
- **External Secrets**: https://external-secrets.io/
- **Nexvion Issues**: Create GitHub issue with `gitops` label

---

**Migration Complete**: The platform now uses GitOps with ArgoCD for all environment deployments. 🎉