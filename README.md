# Nexvion E-Commerce Platform

Production-grade e-commerce platform with complete DevOps lifecycle: Infrastructure as Code, GitOps, CI/CD, Security, and Observability.

## Live Demo
- **Production**: https://nexvion.ghanshyam.site
- **Staging**: https://staging-nexvion.ghanshyam.site
- **Development**: https://nexvion-dev.ghanshyam.site
- **ArgoCD**: https://argocd.ghanshyam.site
- **API Docs**: https://nexvion.ghanshyam.site/docs

---

## Tech Stack

| Layer | Technology | Version |
|-------|------------|---------|
| **Frontend** | Vanilla HTML/CSS/JS, Nginx | Alpine 3.19 |
| **Backend** | Python 3.11, FastAPI, SQLAlchemy 2.0, AsyncPG | 0.115.0 |
| **Database** | PostgreSQL 16 (RDS) / Self-managed EC2 | 16 |
| **AI/ML** | Groq (Llama 3.1), OpenAI fallback, Mock | - |
| **Containerization** | Docker, Docker Compose | 24.0+ |
| **Orchestration** | Kubernetes (EKS) | 1.28 |
| **Infrastructure** | Terraform | 1.6+ |
| **GitOps** | ArgoCD + Kustomize | 2.8+ |
| **CI/CD** | Jenkins (Pipeline) | LTS |
| **Registry** | Amazon ECR | - |
| **DNS/SSL** | Route53, ACM, ALB | - |
| **Monitoring** | Prometheus, Grafana, Loki, Alertmanager | Latest |
| **Logging** | Loki + Promtail + Fluent Bit | 2.9+ |
| **Security** | Trivy, Gitleaks, NetworkPolicies, ExternalSecrets | Latest |
| **Secrets** | AWS Secrets Manager, ExternalSecrets Operator | 0.8+ |
| **Service Mesh** | None (ALB + NetworkPolicies) | - |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            AWS CLOUD (ap-south-1)                           │
├─────────────────────────────────────────────────────────────────────────────┤
│  Route53 (nexvion.ghanshyam.site)                                           │
│       │                                                                     │
│       ▼                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    ALB (Application Load Balancer)                   │   │
│  │  • TLS Termination (ACM Certificate)                                │   │
│  │  • WAF Integration (Production)                                     │   │
│  │  • Target Groups: Frontend, Backend, ArgoCD                         │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│       │                    │                    │                         │
│       ▼                    ▼                    ▼                         │
│  ┌─────────┐         ┌─────────────┐     ┌─────────┐                    │
│  │ Frontend│         │   Backend   │     │ ArgoCD  │                    │
│  │ (Nginx) │         │  (FastAPI)  │     │ (GitOps)│                    │
│  │ HPA:2-10│         │ HPA:2-10    │     │         │                    │
│  └────┬────┘         └──────┬──────┘     └────┬────┘                    │
│       │                     │                   │                       │
│       └─────────────────────┼───────────────────┘                       │
│                             ▼                                           │
│              ┌─────────────────────────────┐                           │
│              │      EKS Cluster (v1.28)    │                           │
│              │  ┌───────────────────────┐  │                           │
│              │  │ Managed Node Groups   │  │                           │
│              │  │ • t3.medium (On-Demand)│  │                           │
│              │  │ • t3.large (Spot)     │  │                           │
│              │  │ • IRSA for ECR/CloudWatch│ │                         │
│              │  └───────────────────────┘  │                           │
│              └─────────────────────────────┘                           │
│                             │                                           │
│              ┌──────────────┼──────────────┐                          │
│              ▼              ▼              ▼                          │
│       ┌────────────┐ ┌────────────┐ ┌────────────┐                   │
│       │  RDS PG16  │ │ElastiCache │ │  OpenSearch│                   │
│       │ Multi-AZ   │ │  Redis 7   │ │  (Logs)    │                   │
│       │ db.t3.med  │ │ cache.t3.m │ │  3 nodes   │                   │
│       └────────────┘ └────────────┘ └────────────┘                   │
└─────────────────────────────────────────────────────────────────────────────┘

External Services:
• GitHub (Source Control)
• Jenkins (CI/CD Pipeline)
• AWS Secrets Manager (ExternalSecrets)
• Groq API / OpenAI API (AI Analysis)
```

### Data Flow

1. **User Request** → Route53 → ALB (TLS termination)
2. **Frontend** (Nginx) serves static assets, proxies `/api/*` to Backend
3. **Backend** (FastAPI) processes requests, connects to PostgreSQL (RDS)
4. **Orders/Products** cached in ElastiCache Redis
5. **Logs** → Fluent Bit → OpenSearch → AI Analyzer (Groq LLM) → Slack/Alerts
6. **Metrics** → Prometheus → Grafana Dashboards
7. **GitOps**: Jenkins → ECR → Kustomize → ArgoCD → EKS

---

## Project Structure

```
nexvion-ecommerce-devops/
├── frontend/                     # Static frontend (Nginx)
│   ├── Dockerfile               # Multi-stage: build → nginx:alpine
│   ├── nginx.conf               # Reverse proxy + caching + security headers
│   ├── *.html, *.css, *.js      # E-commerce pages
│   └── .stylelintrc.json        # Stylelint config
│
├── backend/                      # FastAPI REST API
│   ├── app/
│   │   ├── api/                 # REST endpoints (health, products, orders)
│   │   ├── core/                # Config, security, logging
│   │   ├── db/                  # Async SQLAlchemy, sessions, migrations
│   │   ├── models/              # SQLAlchemy models (Product, Order, OrderItem)
│   │   └── schemas/             # Pydantic request/response schemas
│   ├── tests/                   # Pytest + testcontainers (PostgreSQL)
│   ├── alembic/                 # Database migrations
│   ├── Dockerfile               # Multi-stage: build → python:3.11-slim
│   ├── pyproject.toml           # Ruff, MyPy, pytest config
│   └── requirements.txt         # Production deps
│
├── ai/                           # AI-powered services
│   └── incident-analysis/       # Log analysis with LLM
│       ├── analyzer.py          # Groq → OpenAI → Mock fallback chain
│       ├── Dockerfile
│       └── requirements.txt
│
├── terraform/                    # AWS Infrastructure as Code
│   ├── main.tf                  # Root module
│   ├── terraform.tfvars.example # Example variables
│   ├── environments/            # Dev/Staging/Prod configs
│   │   ├── dev/
│   │   ├── staging/
│   │   └── prod/
│   └── modules/
│       ├── vpc/                 # VPC, subnets, NAT, IGW, VPC endpoints
│       ├── eks/                 # EKS cluster, node groups, IRSA
│       ├── alb/                 # ALB, target groups, listeners
│       ├── rds-postgres/        # RDS PostgreSQL Multi-AZ
│       ├── ec2-postgres/        # Self-managed PG on EC2 (alternative)
│       ├── route53/             # Hosted zone, records, ACM cert
│       └── s3/                  # State bucket, DynamoDB locks
│
├── helm/                         # Helm charts (alternative to Kustomize)
│   └── ecommerce/               # Complete app chart with subcharts
│       ├── Chart.yaml
│       ├── values.yaml          # Production defaults
│       ├── values-dev.yaml      # Dev overrides
│       ├── values-staging.yaml  # Staging overrides
│       ├── values-prod.yaml     # Production overrides
│       └── values-bluegreen.yaml# Blue-green deployment
│
├── gitops-config/               # GitOps (ArgoCD + Kustomize)
│   ├── argocd/
│   │   ├── applications/        # ArgoCD Application CRDs
│   │   │   ├── nexvion-dev.yaml
│   │   │   ├── nexvion-staging.yaml
│   │   │   ├── nexvion-prod.yaml
│   │   │   ├── monitoring.yaml
│   │   │   └── logging.yaml
│   │   ├── projects/            # ArgoCD Project (RBAC)
│   │   └── config/              # ConfigMaps (RBAC, Notifications, Ingress)
│   └── overlays/
│       ├── base/                # Common resources (deployments, services, HPA, etc.)
│       ├── dev/                 # Dev: 1 replica, debug, no monitoring
│       ├── staging/             # Staging: 2 replicas, monitoring
│       └── prod/                # Prod: 3 replicas, WAF, strict RBAC
│
├── observability-infra/         # Observability stack
│   ├── helm/
│   │   ├── monitoring/          # Prometheus, Grafana, Alertmanager
│   │   └── logging/             # Loki, Promtail
│   └── argocd/
│       └── applications/        # ArgoCD apps for observability
│
├── ansible/                     # Legacy EC2 provisioning (backup)
│   ├── inventory.yml
│   ├── playbooks/site.yml
│   └── roles/ (common, nginx, postgresql)
│
├── Jenkins/                     # CI/CD Pipeline
│   ├── orchestrator/Jenkinsfile # Main pipeline
│   ├── backend/Jenkinsfile      # Backend build/test/scan
│   ├── frontend/Jenkinsfile     # Frontend build/test
│   └── ai-analyzer/Jenkinsfile  # AI service build
│
├── docker-compose.yml           # Local development stack
├── filebeat.yml                 # Log shipping config
├── .github/                     # GitHub Actions (backup CI)
└── scripts/                     # Bootstrap, deploy, backup scripts
```

---

## Features

### E-Commerce Core
- **Product Catalog**: 12 products, 4 categories, real-time stock
- **Advanced Filtering**: Category, price range, stock, search
- **Shopping Cart**: Persistent (localStorage), quantity controls
- **Authentication**: JWT-based, register/login, protected routes
- **Checkout**: Multi-step form, delivery details, payment methods
- **Payments**: UPI, Credit/Debit Card, Cash on Delivery
- **Orders**: Confirmation, history, tracking

### DevOps & Platform
- **Infrastructure as Code**: Complete AWS via Terraform modules
- **GitOps**: Kustomize overlays (dev/staging/prod) + ArgoCD
- **CI/CD**: Jenkins multibranch pipeline with stages
- **Security**: Trivy (image/fs), Gitleaks, NetworkPolicies, ExternalSecrets
- **Observability**: Prometheus metrics, Grafana dashboards, Loki logs
- **Auto-scaling**: HPA (CPU 70%), Cluster Autoscaler
- **Blue-Green**: ALB listener rules for zero-downtime deploy
- **Disaster Recovery**: RDS Multi-AZ, automated backups, cross-region replica
- **Rollback**: Git revert → ArgoCD auto-sync (< 2 min)

---

## Quick Start

### Prerequisites
- Docker 24+, Docker Compose 2+
- Python 3.11+ (for local backend dev)
- kubectl, helm, kustomize (for K8s)
- AWS CLI, Terraform 1.6+ (for infra)

### Local Development

```bash
# 1. Clone
git clone https://github.com/your-org/ai-ecommerce-devops.git
cd ai-ecommerce-devops

# 2. Start all services (PostgreSQL, Backend, Frontend, AI Analyzer, OpenSearch)
docker compose up --build -d

# 3. Initialize database (runs migrations + seeds)
docker compose exec backend python -m app.db.init_db

# 4. Access
open http://localhost:8080        # Frontend
open http://localhost:8000/docs   # API Swagger UI
open http://localhost:9200        # OpenSearch (if enabled)
```

### Run Tests

```bash
# Backend
cd backend
python -m pytest tests/ -v --cov=app --cov-report=term-missing
python -m ruff check .
python -m mypy .

# AI Analyzer
cd ../ai/incident-analysis
python -m ruff check .

# YAML validation
cd ../..
yamllint gitops-config/ ansible/ helm/ecommerce/Chart.yaml helm/ecommerce/values*.yaml
```

---

## Production Deployment

### 1. Bootstrap AWS State Backend (One-time)

```bash
# Create S3 bucket for Terraform state
aws s3 mb s3://nexvion-terraform-state --region ap-south-1
aws s3api put-bucket-versioning --bucket nexvion-terraform-state --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket nexvion-terraform-state --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-south-1
```

### 2. Configure Secrets (AWS Secrets Manager)

```bash
# Database password
aws secretsmanager create-secret \
  --name nexvion/prod/db_password \
  --secret-string "your-secure-db-password" \
  --region ap-south-1

# JWT secret
aws secretsmanager create-secret \
  --name nexvion/prod/jwt_secret \
  --secret-string "$(openssl rand -base64 32)" \
  --region ap-south-1

# AI Analyzer API keys
aws secretsmanager create-secret \
  --name nexvion/prod/groq_api_key \
  --secret-string "gsk_..." \
  --region ap-south-1

aws secretsmanager create-secret \
  --name nexvion/prod/openai_api_key \
  --secret-string "sk-..." \
  --region ap-south-1

# Slack webhook for alerts
aws secretsmanager create-secret \
  --name nexvion/prod/slack_webhook \
  --secret-string "https://hooks.slack.com/services/..." \
  --region ap-south-1

# ACM Certificate ARN (create via AWS Console or CLI)
aws secretsmanager create-secret \
  --name nexvion/prod/certificate_arn \
  --secret-string "arn:aws:acm:ap-south-1:XXXXXXXXXXXX:certificate/..." \
  --region ap-south-1
```

### 3. Deploy Infrastructure (Terraform)

```bash
cd terraform

# Initialize with remote backend
terraform init \
  -backend-config="bucket=nexvion-terraform-state" \
  -backend-config="key=prod/terraform.tfstate" \
  -backend-config="region=ap-south-1" \
  -backend-config="dynamodb_table=terraform-locks"

# Review plan
terraform plan \
  -var-file=environments/prod/terraform.tfvars \
  -var="key_pair_name=<YOUR_EC2_KEY_PAIR>" \
  -var="db_password=$(aws secretsmanager get-secret-value --secret-id nexvion/prod/db_password --query SecretString --output text)" \
  -var="certificate_arn=$(aws secretsmanager get-secret-value --secret-id nexvion/prod/certificate_arn --query SecretString --output text)"

# Apply
terraform apply \
  -var-file=environments/prod/terraform.tfvars \
  -var="key_pair_name=<YOUR_EC2_KEY_PAIR>" \
  -var="db_password=$(aws secretsmanager get-secret-value --secret-id nexvion/prod/db_password --query SecretString --output text)" \
  -var="certificate_arn=$(aws secretsmanager get-secret-value --secret-id nexvion/prod/certificate_arn --query SecretString --output text)"
```

**Key Terraform Outputs:**
- `eks_cluster_name` - EKS cluster name
- `rds_endpoint` - PostgreSQL endpoint
- `alb_dns_name` - ALB DNS for Route53
- `ecr_repository_urls` - ECR repo URLs for images

### 4. Configure kubectl

```bash
aws eks update-kubeconfig --name nexvion-prod --region ap-south-1

# Verify
kubectl get nodes
kubectl get ns
```

### 5. Install ArgoCD

```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD (via Helm)
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd \
  --namespace argocd \
  --set server.ingress.enabled=true \
  --set server.ingress.hostname=argocd.ghanshyam.site \
  --set configs.cm.application.instanceLabelKey=argocd.argoproj.io/instance \
  --version 6.5.0

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### 6. Bootstrap GitOps Applications

```bash
# Apply ArgoCD Project and RBAC
kubectl apply -f gitops-config/argocd/projects/nexvion-project.yaml
kubectl apply -f gitops-config/argocd/config/

# Apply Application manifests (dev, staging, prod, monitoring, logging)
kubectl apply -f gitops-config/argocd/applications/
```

### 7. Build & Push Images (Jenkins or Local)

```bash
# Login to ECR
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com

# Build and push
docker build -t <ECR_REGISTRY>/nexvion-frontend:v1.0.0 ./frontend
docker push <ECR_REGISTRY>/nexvion-frontend:v1.0.0

docker build -t <ECR_REGISTRY>/nexvion-backend:v1.0.0 ./backend
docker push <ECR_REGISTRY>/nexvion-backend:v1.0.0

docker build -t <ECR_REGISTRY>/nexvion-ai-analyzer:v1.0.0 ./ai/incident-analysis
docker push <ECR_REGISTRY>/nexvion-ai-analyzer:v1.0.0
```

### 8. Update Kustomize Images

```bash
cd gitops-config/overlays/prod

kustomize edit set image nexvion-frontend=<ECR_REGISTRY>/nexvion-frontend:v1.0.0
kustomize edit set image nexvion-backend=<ECR_REGISTRY>/nexvion-backend:v1.0.0
kustomize edit set image nexvion-ai-analyzer=<ECR_REGISTRY>/nexvion-ai-analyzer:v1.0.0

# Verify
kustomize build . | head -50
```

### 9. Deploy via ArgoCD

```bash
# Option A: ArgoCD UI - Click SYNC on nexvion-prod application
# Option B: CLI
argocd app sync nexvion-prod --prune

# Monitor
argocd app wait nexvion-prod --health --timeout 300
```

### 10. Verify Deployment

```bash
# Check all pods
kubectl get pods -n nexvion

# Check services
kubectl get svc -n nexvion

# Check ingress
kubectl get ingress -n nexvion

# Test endpoints
curl -I https://nexvion.ghanshyam.site
curl https://nexvion.ghanshyam.site/api/health
curl https://nexvion.ghanshyam.site/api/health/detailed
```

---

## Environment Configuration

### GitOps Overlays

| Environment | Replicas | Monitoring | AI Analyzer | Debug | Resources |
|-------------|----------|------------|-------------|-------|-----------|
| **dev** | 1 | Disabled | 60min interval | true | Minimal |
| **staging** | 2 | Enabled (7d retention) | 30min interval | false | Medium |
| **prod** | 3 | Enabled (15d retention) | 15min + alerts | false | Full + WAF |

### Key ConfigMaps & Secrets

```yaml
# Backend ConfigMap (gitops-config/overlays/base/kustomize-resources/backend-configmap.yaml)
DATABASE_URL: from ExternalSecrets (AWS Secrets Manager)
JWT_SECRET_KEY: from ExternalSecrets
CORS_ORIGINS: ["https://nexvion.ghanshyam.site"]
DEBUG: "false"

# Frontend ConfigMap (nginx.conf)
proxy_pass http://nexvion-backend:8000;
security headers: X-Frame-Options, X-Content-Type-Options, etc.
```

---

## CI/CD Pipeline (Jenkins)

### Pipeline Stages

```groovy
// Jenkins/orchestrator/Jenkinsfile
pipeline {
    agent { label 'docker' }
    stages {
        stage('Checkout') { /* git checkout */ }
        stage('Lint & Type Check') {
            parallel {
                'Backend': { /* ruff, mypy */ }
                'Frontend': { /* stylelint */ }
                'AI': { /* ruff */ }
                'YAML': { /* yamllint */ }
            }
        }
        stage('Unit Tests') {
            parallel {
                'Backend': { /* pytest + coverage */ }
            }
        }
        stage('Security Scan') {
            parallel {
                'Trivy FS': { /* trivy fs . */ }
                'Trivy Image': { /* trivy image */ }
                'Gitleaks': { /* gitleaks detect */ }
            }
        }
        stage('Build & Push') {
            parallel {
                'Frontend': { /* docker build/push to ECR */ }
                'Backend': { /* docker build/push to ECR */ }
                'AI Analyzer': { /* docker build/push to ECR */ }
            }
        }
        stage('GitOps Update') {
            steps {
                /* Update kustomize images in gitops-config/overlays/${ENV} */
                /* Commit & push to GitOps repo */
            }
        }
        stage('Deploy') {
            when { expression { env.BRANCH_NAME == 'main' || params.FORCE_DEPLOY } }
            steps {
                /* ArgoCD sync via CLI or API */
                /* Manual approval for production */
            }
        }
    }
}
```

### Triggers
- **Push to `develop`** → Auto-deploy to `dev` namespace
- **Push to `staging`** → Auto-deploy to `staging` namespace
- **PR to `main`** → Build + test only
- **Merge to `main`** → Manual approval → Deploy to `prod`
- **Scheduled** → Nightly security scans, dependency updates

---

## Security Implementation

### Container Security
```dockerfile
# Backend Dockerfile - Non-root, minimal
FROM python:3.11-slim AS base
RUN useradd --create-home --shell /bin/bash appuser
USER appuser
# No shell, no package manager in final image

# Frontend Dockerfile
FROM nginx:alpine
# Runs as nginx user (UID 101)
```

### Kubernetes Security
- **NetworkPolicies**: Default deny, explicit allow per service
- **PodSecurityStandards**: Restricted profile
- **RBAC**: Least-privilege ServiceAccounts, ArgoCD Project RBAC
- **Secrets**: ExternalSecrets Operator → AWS Secrets Manager (no plaintext in Git)
- **IRSA**: IAM Roles for Service Accounts (ECR pull, CloudWatch, S3)

### Pipeline Security
- **Trivy**: Filesystem scan (PR), Image scan (post-build)
- **Gitleaks**: Secret detection on every commit
- **Dependency Check**: `pip-audit` in backend build
- **Image Signing**: Cosign (optional, for supply chain)

---

## Observability Stack

### Metrics (Prometheus + Grafana)
| Dashboard | Description |
|-----------|-------------|
| **Kubernetes Cluster** | Node, pod, container metrics |
| **Application (RED)** | Rate, Errors, Duration per endpoint |
| **Business** | Orders/min, Revenue, Conversion |
| **Database** | Connections, Query latency, Cache hit ratio |
| **Infrastructure** | ALB, RDS, ElastiCache metrics |

### Alerts (Alertmanager → Slack/PagerDuty)
```yaml
# Critical: API down, DB unavailable, Disk full
# Warning: High latency (>2s), Error rate >5%, HPA scaling
# Info: New deployment, Config change
```

### Logging (Loki + Promtail)
- **Labels**: namespace, pod, container, app, level
- **Retention**: Dev 1d, Staging 7d, Prod 30d
- **AI Analysis**: Runs every 15min (prod), analyzes ERROR/CRITICAL logs via Groq LLM

### Distributed Tracing (Optional)
- OpenTelemetry SDK in FastAPI
- Export to Tempo or Jaeger

---

## Cost Optimization

### Production (ap-south-1) Monthly Estimate

| Component | Config | Monthly Cost |
|-----------|--------|-------------|
| EKS Control Plane | Standard | $73.00 |
| EKS Nodes (2× t3.medium On-Demand) | 2 vCPU, 4GB RAM | $60.00 |
| EKS Nodes (2× t3.large Spot) | 2 vCPU, 8GB RAM | $25.00 |
| NAT Gateway (2 AZ) | 45 GB/hr | $45.00 |
| ALB | 10 LCUs | $25.00 |
| RDS PostgreSQL (db.t3.medium Multi-AZ) | 2 vCPU, 4GB, 100GB | $85.00 |
| ElastiCache Redis (cache.t3.micro) | 2 nodes | $25.00 |
| OpenSearch (3× t3.small.search) | 2 vCPU, 4GB, 20GB | $90.00 |
| ECR Storage | ~10 GB | $1.00 |
| CloudWatch Logs/Metrics | Standard | $15.00 |
| **Total** | | **~$444/month** |

### Cost Reduction Strategies
- **Spot Instances**: 60-70% savings on worker nodes
- **RDS Aurora Serverless v2**: Auto-scale, pay-per-use
- **Frontend on CloudFront + S3**: Eliminate Nginx pods (~$60/mo)
- **Graviton2/3 (ARM)**: 20% better price/performance
- **Scheduled Scaling**: Scale to 0 at night for dev/staging

---

## Disaster Recovery

| Scenario | RTO | RPO | Implementation |
|----------|-----|-----|----------------|
| **Pod Failure** | <30s | 0 | HPA + Liveness/Readiness probes |
| **Node Failure** | <2min | 0 | Cluster Autoscaler + PodDisruptionBudgets |
| **AZ Failure** | <5min | 0 | Multi-AZ RDS, ALB, EKS nodes |
| **Region Failure** | <30min | <1hr | Cross-region RDS replica, S3 CRR |
| **Data Corruption** | <1hr | <5min | RDS automated backups (7d), Point-in-time recovery |
| **GitOps Repo Loss** | <1hr | 0 | GitHub protected branches, mirrored repo |

### Backup Strategy
```bash
# RDS: Automated daily snapshots (7d retention) + point-in-time recovery
# EKS: Velero backups to S3 (daily, 30d retention)
# Secrets: AWS Secrets Manager automatic rotation (90d)
# Config: All in Git (GitOps), GitHub protected branches
```

---

## Troubleshooting

### Common Issues

| Issue | Diagnosis | Resolution |
|-------|-----------|------------|
| **Pods stuck Pending** | `kubectl describe pod` | Check node resources, PVC binding, taints |
| **502 Bad Gateway** | ALB target health | Check backend pod readiness, security groups |
| **DB Connection Timeout** | `kubectl logs backend` | Check RDS security group, Secrets Manager sync |
| **ArgoCD OutOfSync** | `argocd app diff` | Manual sync or check Kustomize build |
| **High Memory** | Grafana dashboard | Increase limits, check for leaks |
| **AI Analyzer Errors** | `kubectl logs ai-analyzer` | Check Groq/OpenAI API keys, OpenSearch connectivity |

### Debug Commands

```bash
# Pod logs
kubectl logs -n nexvion -l app.kubernetes.io/component=backend -f

# Port forward for local debugging
kubectl port-forward -n nexvion svc/nexvion-backend 8000:8000

# Check ExternalSecrets sync
kubectl get externalsecrets -n nexvion
kubectl describe externalsecret nexvion-backend-secrets -n nexvion

# ArgoCD sync status
argocd app get nexvion-prod
argocd app sync nexvion-prod --dry-run

# Kustomize build validation
kustomize build gitops-config/overlays/prod
```

---

## API Reference

### Health
- `GET /api/health` - Basic health (liveness)
- `GET /api/health/detailed` - Deep checks (DB, cache, dependencies)

### Products
- `GET /api/products` - List (query: category, min_price, max_price, in_stock, search, page, limit)
- `GET /api/products/categories` - All categories
- `GET /api/products/{id}` - Single product
- `POST /api/products` - Create (admin)
- `PATCH /api/products/{id}` - Update (admin)
- `DELETE /api/products/{id}` - Delete (admin)

### Orders
- `POST /api/orders` - Create order
- `GET /api/orders/{order_id}` - Get order
- `GET /api/orders` - List (query: user_email, status, page, limit)

---

## Contributing

1. Fork repository
2. Create feature branch: `git checkout -b feature/amazing-feature`
3. Run all checks locally:
   ```bash
   cd backend && ruff check . && mypy . && pytest
   cd ../ai/incident-analysis && ruff check .
   cd ../.. && yamllint gitops-config/ ansible/ helm/
   ```
4. Commit with conventional commits: `git commit -m 'feat: add amazing feature'`
5. Push and open PR
6. CI/CD runs automatically, ArgoCD deploys on merge to main

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Support

- **Issues**: https://github.com/your-org/ai-ecommerce-devops/issues
- **Documentation**: This README + inline code comments
- **Slack**: #nexvion-platform
- **On-call**: PagerDuty rotation