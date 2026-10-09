# Architecture Documentation

## System Overview

Nexvion E-Commerce Platform is a cloud-native, microservices-oriented application deployed on AWS with full GitOps lifecycle management.

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              USERS (Global)                                          │
└─────────────────────────────────────┬───────────────────────────────────────────────┘
                                      │ HTTPS/TLS 1.3
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                            AWS EDGE SERVICES                                         │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐                     │
│  │   Route 53      │  │   CloudFront    │  │   WAF v2        │                     │
│  │   (DNS)         │  │   (Static)      │  │   (Protection)  │                     │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘                     │
└─────────────────────────────────────┬───────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                     APPLICATION LOAD BALANCER (ALB)                                  │
│  • TLS Termination (ACM Certificate)                                                │
│  • Path-based Routing: / → Frontend, /api/* → Backend, /argocd → ArgoCD            │
│  • Target Groups: Frontend (HTTP:80), Backend (HTTP:8000), ArgoCD (HTTP:8080)      │
│  • Health Checks: /api/health (Backend), / (Frontend)                               │
│  • SSL Redirect: HTTP → HTTPS (301)                                                 │
└─────────────────────────────────────┬───────────────────────────────────────────────┘
                                      │
              ┌───────────────────────┼───────────────────────┐
              ▼                       ▼                       ▼
┌─────────────────────────┐ ┌─────────────────────────┐ ┌─────────────────────────┐
│      FRONTEND TIER      │ │       BACKEND TIER      │ │       ARGOCD TIER       │
│   (Nginx + Static)      │ │      (FastAPI)          │ │      (GitOps)           │
│                         │ │                         │ │                         │
│ • 3 Replicas (HPA 2-10) │ │ • 3 Replicas (HPA 2-10) │ │ • 1 Replica             │
│ • Nginx Reverse Proxy   │ │ • Async FastAPI         │ │ • App of Apps Pattern   │
│ • Gzip, Caching, CSP    │ │ • SQLAlchemy 2.0 Async  │ • RBAC: Admin/Dev/Read    │
│ • Security Headers      │ • JWT Authentication      │ • Slack Notifications     │
│ • CloudFront Ready      │ • Prometheus Metrics      │ • Auto-sync Dev/Staging   │
└───────────┬─────────────┘ └───────────┬─────────────┘ └───────────┬─────────────┘
            │                           │                           │
            │              ┌────────────┴────────────┐              │
            │              ▼                       ▼              │
            │  ┌─────────────────┐          ┌─────────────────┐   │
            │  │  POSTGRESQL     │          │  ELASTICACHE    │   │
            │  │  (RDS Multi-AZ) │          │  REDIS 7        │   │
            │  │                 │          │                 │   │
            │  │ • db.t3.medium  │          │ • cache.t3.micro│   │
            │  │ • 100GB GP3     │          │ • 2 Nodes       │   │
            │  │ • Multi-AZ      │          │ • Cluster Mode  │   │
            │  │ • 7d Backups    │          │ • TLS Enabled   │   │
            │  │ • PITR          │          │                 │   │
            │  └─────────────────┘          └─────────────────┘   │
            │                           │                           │
            └───────────────────────────┼───────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                        OBSERVABILITY STACK                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐            │
│  │ Prometheus   │  │  Grafana     │  │    Loki      │  │ Alertmanager │            │
│  │ (Metrics)    │  │ (Dashboards) │  │   (Logs)     │  │ (Alerts)     │            │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘            │
│         │                  │                  │                  │                   │
│         ▼                  ▼                  ▼                  ▼                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │                    AI INCIDENT ANALYZER (Groq LLM)                           │   │
│  │  • Collects ERROR/CRITICAL logs from OpenSearch/Loki every 15min            │   │
│  │  • Analyzes via Groq (Llama 3.1) → OpenAI fallback → Mock                  │   │
│  │  • Outputs: Classification, Root Cause, Investigation, Remediation          │   │
│  │  • Alerts to Slack for Critical/High severity                               │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Details

### Frontend (Nginx)

**Technology**: Nginx 1.25 on Alpine 3.19
**Deployment**: Deployment with HPA (2-10 replicas, CPU 70%)
**Configuration**:
```nginx
# Key features in nginx.conf
- Reverse proxy to backend: /api/ → http://nexvion-backend:8000
- Static asset caching: 1 year for .js, .css, .png, .jpg, .woff2
- Security headers: X-Frame-Options, X-Content-Type-Options, X-XSS-Protection
- Gzip compression: text, css, js, json, xml
- Rate limiting: 100 req/s per IP (configurable)
- Health endpoint: /health → proxied to backend
```

**Docker**: Multi-stage build
```dockerfile
FROM nginx:alpine
COPY nginx.conf /etc/nginx/nginx.conf
COPY . /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

**Resources**:
- Requests: 100m CPU, 64Mi Memory
- Limits: 500m CPU, 128Mi Memory

---

### Backend (FastAPI)

**Technology**: Python 3.11, FastAPI 0.115, SQLAlchemy 2.0, AsyncPG
**Deployment**: Deployment with HPA (2-10 replicas, CPU 70%)
**API Endpoints**:
```
GET    /api/health                    # Liveness probe
GET    /api/health/detailed           # Readiness probe (DB, Cache, Deps)
GET    /api/products                  # List with filters
GET    /api/products/categories       # Categories
GET    /api/products/{id}             # Single product
POST   /api/products                  # Create (admin)
PATCH  /api/products/{id}             # Update (admin)
DELETE /api/products/{id}             # Delete (admin)
POST   /api/orders                    # Create order
GET    /api/orders/{order_id}         # Get order
GET    /api/orders                    # List orders
GET    /metrics                       # Prometheus metrics
```

**Database Models**:
```python
# Product
id, name, category, price, stock, tag, image_url, description, created_at, updated_at

# Order
id, order_id, user_name, user_email, phone, address, city, pin_code,
payment_method, payment_details, subtotal, status, created_at, updated_at

# OrderItem
id, order_id, product_id, product_name, product_category,
product_price, product_image, quantity
```

**Configuration** (via ConfigMap + ExternalSecrets):
```yaml
DATABASE_URL: postgresql+asyncpg://user:pass@host:5432/db
JWT_SECRET_KEY: <from AWS Secrets Manager>
DATABASE_POOL_SIZE: 5
DATABASE_MAX_OVERFLOW: 10
CORS_ORIGINS: ["https://nexvion.ghanshyam.site"]
DEBUG: "false"
```

**Security**:
- Non-root container (UID 1000)
- JWT authentication (RS256)
- Input validation via Pydantic
- SQL injection prevention (SQLAlchemy ORM)
- CORS restricted to production domain

**Resources**:
- Requests: 250m CPU, 256Mi Memory
- Limits: 1000m CPU, 512Mi Memory

---

### Database (PostgreSQL)

**Technology**: PostgreSQL 16 on RDS (Multi-AZ)
**Configuration**:
```yaml
Instance Class: db.t3.medium (2 vCPU, 4 GB RAM)
Storage: 100 GB GP3 (3000 IOPS baseline)
Multi-AZ: Yes (synchronous replication)
Backup: 7 days retention, point-in-time recovery
Encryption: AES-256 at rest, TLS 1.2 in transit
Parameters:
  max_connections: 100
  shared_buffers: 1GB
  effective_cache_size: 3GB
  work_mem: 4MB
  maintenance_work_mem: 256MB
```

**Schema**:
```sql
-- Products table
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    category VARCHAR(100) NOT NULL,
    price NUMERIC(10,2) NOT NULL,
    stock BOOLEAN NOT NULL DEFAULT true,
    tag VARCHAR(50),
    image_url TEXT NOT NULL,
    description TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX ix_products_category ON products(category);

-- Orders table
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    order_id VARCHAR(50) UNIQUE NOT NULL,
    user_name VARCHAR(255) NOT NULL,
    user_email VARCHAR(255) NOT NULL,
    phone VARCHAR(20) NOT NULL,
    address TEXT NOT NULL,
    city VARCHAR(100) NOT NULL,
    pin_code VARCHAR(10) NOT NULL,
    payment_method VARCHAR(20) NOT NULL,
    payment_details TEXT,
    subtotal NUMERIC(10,2) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX ix_orders_order_id ON orders(order_id);

-- Order Items table
CREATE TABLE order_items (
    id SERIAL PRIMARY KEY,
    order_id INTEGER REFERENCES orders(id) ON DELETE CASCADE,
    product_id INTEGER NOT NULL,
    product_name VARCHAR(255) NOT NULL,
    product_category VARCHAR(100) NOT NULL,
    product_price NUMERIC(10,2) NOT NULL,
    product_image TEXT NOT NULL,
    quantity INTEGER NOT NULL
);
CREATE INDEX ix_order_items_order_id ON order_items(order_id);
```

---

### AI Incident Analyzer

**Technology**: Python 3.11, Groq API (Llama 3.1), OpenAI fallback
**Deployment**: CronJob (every 15 min) + Deployment (continuous mode)
**Architecture**:
```
┌─────────────────────────────────────────────────────────────────┐
│                    AI INCIDENT ANALYZER                         │
├─────────────────────────────────────────────────────────────────┤
│  LogCollector                                                    │
│  ├── OpenSearch Client (production)                             │
│  └── Mock Data (development)                                    │
│                    │                                             │
│                    ▼                                             │
│  LLMAnalyzer (Priority Chain)                                    │
│  ├── 1. Groq (Llama 3.1 8B) - Primary, Free                    │
│  ├── 2. OpenAI (GPT-4o-mini) - Fallback, Paid                  │
│  └── 3. Mock Analysis - Final fallback                          │
│                    │                                             │
│                    ▼                                             │
│  Output: IncidentReport                                          │
│  ├── error_classification: database|network|auth|timeout|...   │
│  ├── severity: critical|high|medium|low                         │
│  ├── possible_root_cause: string                                │
│  ├── suggested_investigation: string[]                          │
│  ├── suggested_remediation: string[]                            │
│  ├── confidence: 0.0-1.0                                        │
│  └── log_samples: string[]                                      │
└─────────────────────────────────────────────────────────────────┘
```

**Configuration**:
```yaml
GROQ_API_KEY: <from AWS Secrets Manager>
GROQ_MODEL: llama-3.1-8b-instant
OPENAI_API_KEY: <from AWS Secrets Manager>
OPENAI_MODEL: gpt-4o-mini
OPENSEARCH_HOST: opensearch.monitoring.svc.cluster.local
OPENSEARCH_PORT: 9200
OPENSEARCH_USER: admin
OPENSEARCH_PASSWORD: <from AWS Secrets Manager>
OPENSEARCH_SSL: "true"
OPENSEARCH_VERIFY: "false"
OPENSEARCH_INDEX: "logs-*"
ALERT_WEBHOOK: <Slack webhook from Secrets Manager>
INTERVAL_MINUTES: 15
```

**Resources**:
- Requests: 100m CPU, 128Mi Memory
- Limits: 500m CPU, 256Mi Memory

---

### Infrastructure (Terraform)

**Module Structure**:
```
terraform/
├── main.tb                      # Root module
├── environments/
│   ├── dev/terraform.tfvars     # Dev config
│   ├── staging/terraform.tfvars # Staging config
│   └── prod/terraform.tfvars    # Prod config
└── modules/
    ├── vpc/                     # VPC, Subnets, NAT, IGW, Endpoints
    ├── eks/                     # EKS Cluster, Node Groups, IRSA
    ├── alb/                     # ALB, Target Groups, Listeners
    ├── rds-postgres/            # RDS PostgreSQL Multi-AZ
    ├── ec2-postgres/            # Self-managed PG on EC2 (alt)
    ├── route53/                 # Hosted Zone, Records, ACM
    └── s3/                      # State Bucket, DynamoDB Locks
```

**Key Resources Created**:
- **VPC**: 10.0.0.0/16, 3 AZs, Public/Private/DB subnets
- **EKS**: v1.28, Managed Node Groups (On-Demand + Spot), IRSA
- **RDS**: PostgreSQL 16, Multi-AZ, 100GB GP3, Encrypted
- **ALB**: Internet-facing, TLS termination, WAF (prod)
- **Route53**: Hosted zone, A records (ALB alias), ACM cert
- **ECR**: 3 repositories (frontend, backend, ai-analyzer)
- **Secrets Manager**: All application secrets
- **ElastiCache**: Redis 7, Cluster mode, 2 nodes
- **OpenSearch**: 3 data nodes, t3.small.search, 20GB each

---

### GitOps (ArgoCD + Kustomize)

**Repository Structure**:
```
gitops-config/
├── argocd/
│   ├── applications/            # ArgoCD Application CRDs
│   │   ├── nexvion-dev.yaml
│   │   ├── nexvion-staging.yaml
│   │   ├── nexvion-prod.yaml
│   │   ├── monitoring.yaml
│   │   └── logging.yaml
│   ├── projects/                # ArgoCD Project (RBAC)
│   └── config/                  # ConfigMaps
│       ├── argocd-rbac-cm.yaml
│       ├── argocd-notifications-cm.yaml
│       ├── argocd-ingress.yaml
│       └── external-secrets-rbac.yaml
└── overlays/
    ├── base/                    # Common resources
    │   ├── kustomization.yaml
    │   ├── kustomize-resources/ (deployments, services, HPA, etc.)
    │   ├── patches/ (common labels, annotations)
    │   └── external-secrets/ (ClusterSecretStore, ExternalSecrets)
    ├── dev/                     # Dev: 1 replica, debug, no monitoring
    ├── staging/                 # Staging: 2 replicas, monitoring
    └── prod/                    # Prod: 3 replicas, WAF, strict RBAC
```

**Kustomize Base Resources**:
```yaml
# Each component has:
- Deployment (with HPA, probes, resources, securityContext)
- Service (ClusterIP)
- ConfigMap (non-secret config)
- Secret (via ExternalSecrets)
- HPA (CPU 70%, min/max replicas)
- PodDisruptionBudget (minAvailable: 50%)
- NetworkPolicy (default deny, explicit allow)
- ServiceMonitor (Prometheus metrics)
```

**Environment Overlays** (patches):
```yaml
# dev: replicaCount=1, debug=true, monitoring=disabled
# staging: replicaCount=2, monitoring=enabled (7d retention)
# prod: replicaCount=3, WAF=enabled, strict RBAC, 15d retention
```

---

### CI/CD Pipeline (Jenkins)

**Pipeline Structure**:
```
orchestrator/Jenkinsfile (Main)
├── Stage: Checkout
├── Stage: Lint & Type Check (Parallel)
│   ├── Backend: ruff, mypy
│   ├── Frontend: stylelint
│   ├── AI: ruff
│   └── YAML: yamllint
├── Stage: Unit Tests (Parallel)
│   └── Backend: pytest + coverage
├── Stage: Security Scan (Parallel)
│   ├── Trivy Filesystem
│   ├── Trivy Image Scan
│   └── Gitleaks Secret Detection
├── Stage: Build & Push (Parallel)
│   ├── Frontend: docker buildx → ECR
│   ├── Backend: docker buildx → ECR
│   └── AI Analyzer: docker buildx → ECR
├── Stage: GitOps Update
│   └── Update kustomize images → commit → push
└── Stage: Deploy (Conditional)
    ├── Dev: Auto on develop branch
    ├── Staging: Auto on staging branch
    └── Prod: Manual approval on main
```

**Security Gates**:
- All stages must pass
- Trivy: Fail on HIGH/CRITICAL
- Gitleaks: Fail on any secret
- Coverage: Minimum 80% (backend)
- Image signing: Cosign (optional)

---

### Security Architecture

**Network Security**:
```
┌─────────────────────────────────────────────────────────────────┐
│                      VPC (10.0.0.0/16)                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │ Public Subnets  │  │ Private Subnets │  │ DB Subnets      │  │
│  │ (ALB, NAT GW)   │  │ (EKS Nodes,     │  │ (RDS,          │  │
│  │                 │  │  App Pods)      │  │  ElastiCache,   │  │
│  │ AZ-a: 10.0.101  │  │                 │  │  OpenSearch)    │  │
│  │ AZ-b: 10.0.102  │  │ AZ-a: 10.0.1    │  │                 │  │
│  │ AZ-c: 10.0.103  │  │ AZ-b: 10.0.2    │  │ AZ-a: 10.0.11   │  │
│  │                 │  │ AZ-c: 10.0.3    │  │ AZ-b: 10.0.12   │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**Security Groups**:
| Component | Ingress | Egress |
|-----------|---------|--------|
| ALB | 80/443 from 0.0.0.0/0 | 80/8000 to EKS nodes |
| EKS Nodes | 80/8000 from ALB SG | 443 to AWS APIs, 5432 to RDS, 6379 to Redis |
| RDS | 5432 from EKS SG | None |
| ElastiCache | 6379 from EKS SG | None |
| OpenSearch | 9200 from EKS SG | None |

**Kubernetes NetworkPolicies**:
```yaml
# Default deny all
- DefaultDenyIngress
- DefaultDenyEgress

# Explicit allow
- Frontend → Backend (port 8000)
- Backend → RDS (port 5432)
- Backend → Redis (port 6379)
- AI Analyzer → OpenSearch (port 9200)
- All → DNS (port 53)
- Monitoring → All pods (metrics ports)
```

**Secrets Management**:
```
Git (Plaintext)          AWS Secrets Manager           K8s (ExternalSecrets)
─────────────────        ─────────────────────         ────────────────────
❌ DB_PASSWORD           ✅ nexvion/prod/db_password   ✅ Synced to K8s Secret
❌ JWT_SECRET            ✅ nexvion/prod/jwt_secret     ✅ Synced to K8s Secret
❌ GROQ_API_KEY          ✅ nexvion/prod/groq_api_key   ✅ Synced to K8s Secret
❌ OPENAI_API_KEY        ✅ nexvion/prod/openai_key     ✅ Synced to K8s Secret
❌ SLACK_WEBHOOK         ✅ nexvion/prod/slack_webhook  ✅ Synced to K8s Secret
❌ CERT_ARN              ✅ nexvion/prod/cert_arn       ✅ Synced to K8s Secret
```

---

## Data Flow

### Request Flow (User → Order)
```
1. User → https://nexvion.ghanshyam.site
         │
         ▼
2. Route53 → ALB (TLS termination)
         │
         ▼
3. ALB → Frontend (Nginx) [Port 80]
         │
         ├── Static assets → Served directly (cached)
         │
         └── /api/* → Proxy to Backend
                    │
                    ▼
4. Backend (FastAPI) [Port 8000]
         │
         ├── Validate JWT (if protected)
         ├── Query PostgreSQL (RDS)
         │       │
         │       ├── Cache check: Redis (products, categories)
         │       │       │
         │       │       ├── Hit → Return cached
         │       │       └── Miss → Query DB → Cache → Return
         │       │
         │       └── Write: Orders → DB (transaction)
         │
         ├── Emit metrics (Prometheus)
         ├── Log structured JSON (stdout → Fluent Bit → Loki)
         │
         ▼
5. Response → Frontend → ALB → User
```

### Observability Flow
```
Application Logs (stdout)
         │
         ▼
    Fluent Bit (DaemonSet)
         │
         ├── → Loki (logs)
         │       │
         │       └── → AI Analyzer (every 15min)
         │               │
         │               └── → Slack Alert (Critical/High)
         │
         └── → OpenSearch (optional, for AI Analyzer)
         
Metrics (Prometheus)
         │
         ├── → Prometheus Server (scrape 30s)
         │       │
         │       ├── → Grafana (dashboards)
         │       └── → Alertmanager
         │               │
         │               └── → Slack/PagerDuty
         │
         └── → ServiceMonitors (kube-state-metrics, node-exporter)
```

---

## Deployment Topology

### Development
```
┌─────────────────────────────────────────────────────────────┐
│                    DEV ENVIRONMENT                          │
├─────────────────────────────────────────────────────────────┤
│  Namespace: nexvion-dev                                     │
│  Replicas: 1 (all components)                               │
│  Resources: Minimal (100m CPU, 128Mi)                       │
│  Monitoring: Disabled                                       │
│  AI Analyzer: 60min interval, no alerts                     │
│  Debug: true, SQL echo: true                                │
│  Ingress: nexvion-dev.ghanshyam.site                        │
└─────────────────────────────────────────────────────────────┘
```

### Staging
```
┌─────────────────────────────────────────────────────────────┐
│                    STAGING ENVIRONMENT                       │
├─────────────────────────────────────────────────────────────┤
│  Namespace: nexvion-staging                                 │
│  Replicas: 2 (all components)                               │
│  Resources: Medium (250m CPU, 256Mi)                        │
│  Monitoring: Enabled (7d retention)                         │
│  AI Analyzer: 30min interval, alerts to #staging-alerts     │
│  Debug: false                                               │
│  Ingress: staging-nexvion.ghanshyam.site                    │
└─────────────────────────────────────────────────────────────┘
```

### Production
```
┌─────────────────────────────────────────────────────────────┐
│                    PROD ENVIRONMENT                          │
├─────────────────────────────────────────────────────────────┤
│  Namespace: nexvion                                         │
│  Replicas: 3 (all components)                               │
│  Resources: Full (500m CPU, 512Mi backend)                  │
│  Monitoring: Enabled (15d retention)                        │
│  AI Analyzer: 15min interval, alerts to #prod-alerts        │
│  WAF: Enabled on ALB                                        │
│  Debug: false                                               │
│  Ingress: nexvion.ghanshyam.site (ALB + WAF)                │
│  Blue-Green: Supported via ALB Listener Rules               │
└─────────────────────────────────────────────────────────────┘
```

---

## Disaster Recovery

### RTO/RPO Targets
| Scenario | RTO | RPO |
|----------|-----|-----|
| Pod Failure | < 30s | 0 |
| Node Failure | < 2min | 0 |
| AZ Failure | < 5min | 0 |
| Region Failure | < 30min | < 1hr |
| Data Corruption | < 1hr | < 5min |
| GitOps Repo Loss | < 1hr | 0 |

### Backup Strategy
| Component | Frequency | Retention | Method |
|-----------|-----------|-----------|--------|
| RDS | Daily + Continuous | 7d + PITR | Automated |
| EKS (Velero) | Daily | 30d | S3 |
| Secrets Manager | N/A | N/A | Auto-rotation (90d) |
| GitOps Config | Continuous | Forever | GitHub |

---

## Cost Breakdown (Production, ap-south-1)

| Service | Configuration | Monthly Cost |
|---------|---------------|--------------|
| EKS Control Plane | Standard | $73.00 |
| EKS Nodes (2× t3.medium OD) | 2 vCPU, 4GB | $60.00 |
| EKS Nodes (2× t3.large Spot) | 2 vCPU, 8GB | $25.00 |
| NAT Gateway (2 AZ) | 45 GB/hr | $45.00 |
| ALB | 10 LCU | $25.00 |
| RDS PostgreSQL (db.t3.medium Multi-AZ) | 2 vCPU, 4GB, 100GB | $85.00 |
| ElastiCache Redis (cache.t3.micro ×2) | 2 nodes | $25.00 |
| OpenSearch (3× t3.small.search) | 2 vCPU, 4GB, 20GB | $90.00 |
| ECR Storage | ~10 GB | $1.00 |
| CloudWatch Logs/Metrics | Standard | $15.00 |
| **Total** | | **~$444/month** |

### Cost Optimization
- **Spot Instances**: 60-70% savings on workers
- **Aurora Serverless v2**: Auto-scale, pay-per-use
- **CloudFront + S3**: Move frontend off EKS (~$60/mo savings)
- **Graviton3 (ARM)**: 20% better price/performance
- **Scheduled Scaling**: Scale to 0 at night (dev/staging)

---

## Future Enhancements

### Phase 1 (Near-term)
- [ ] Service Mesh (Istio/Linkerd) for mTLS, traffic splitting
- [ ] Distributed Tracing (Tempo + OpenTelemetry)
- [ ] Feature Flags (LaunchDarkly/Unleash)
- [ ] Database Read Replicas for read scaling

### Phase 2 (Medium-term)
- [ ] Multi-region Active-Passive (DR)
- [ ] Event-driven Architecture (Kafka/EventBridge)
- [ ] Machine Learning Pipeline (SageMaker for recommendations)
- [ ] Advanced Rate Limiting (Token Bucket per user)

### Phase 3 (Long-term)
- [ ] Serverless Migration (Lambda/Fargate for sporadic workloads)
- [ ] Edge Computing (CloudFront Functions for A/B testing)
- [ ] Zero Trust Network (BeyondCorp style)
- [ ] Chaos Engineering (Litmus/Gremlin)

---

## Appendix: Mermaid Diagrams

### Component Diagram
```mermaid
graph TB
    User[User] --> Route53[Route53 DNS]
    Route53 --> ALB[ALB TLS Termination]
    ALB --> Frontend[Nginx Frontend]
    ALB --> Backend[FastAPI Backend]
    ALB --> ArgoCD[ArgoCD GitOps]
    
    Frontend -->|Static Assets| User
    Frontend -->|/api/*| Backend
    
    Backend -->|Read/Write| RDS[(RDS PostgreSQL)]
    Backend -->|Cache| Redis[(ElastiCache Redis)]
    Backend -->|Metrics| Prometheus
    Backend -->|Logs| Loki
    
    AI[AI Analyzer] -->|Queries| OpenSearch
    AI -->|Analyzes| Groq[Groq LLM]
    AI -->|Alerts| Slack
    
    ArgoCD -->|Sync| EKS[EKS Cluster]
    Jenkins -->|Build/Push| ECR[ECR Registry]
    ECR -->|Pull| EKS
```

### Deployment Pipeline
```mermaid
graph LR
    Code[Code Push] --> Lint[Lint & Type Check]
    Lint --> Test[Unit Tests]
    Test --> Scan[Security Scan]
    Scan --> Build[Build & Push Images]
    Build --> GitOps[Update GitOps Config]
    GitOps --> ArgoCD[ArgoCD Sync]
    ArgoCD -->|Auto| Dev[Dev Namespace]
    ArgoCD -->|Auto| Staging[Staging Namespace]
    ArgoCD -->|Manual| Prod[Prod Namespace]
```

---
*Last Updated: 2026-10-09*
*Version: 1.0.0*