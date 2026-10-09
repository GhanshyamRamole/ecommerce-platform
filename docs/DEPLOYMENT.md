# Production Deployment Guide

Complete step-by-step guide to deploy Nexvion E-Commerce Platform to AWS Production.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [AWS Account Setup](#aws-account-setup)
3. [State Backend Bootstrap](#state-backend-bootstrap)
4. [Secrets Configuration](#secrets-configuration)
5. [Infrastructure Deployment](#infrastructure-deployment)
6. [Kubernetes Cluster Access](#kubernetes-cluster-access)
7. [ArgoCD Installation](#argocd-installation)
8. [GitOps Bootstrap](#gitops-bootstrap)
9. [Container Images](#container-images)
10. [Application Deployment](#application-deployment)
11. [DNS & SSL Configuration](#dns--ssl-configuration)
12. [Post-Deployment Verification](#post-deployment-verification)
13. [Rollback Procedure](#rollback-procedure)
14. [Monitoring & Alerting Setup](#monitoring--alerting-setup)

---

## Prerequisites

### Required Tools (Local Machine)
```bash
# Versions used in this guide
aws --version          # 2.15+
terraform --version    # 1.6+
kubectl version        # 1.28+
helm version           # 3.13+
kustomize version      # 5.4+
docker --version       # 24.0+
argocd version         # 2.8+
jq --version           # 1.6+
```

### AWS Permissions Required
The deployment role/user needs these policies:
- `AdministratorAccess` (or custom policy with):
  - EC2, VPC, RDS, EKS, ALB, Route53, ACM, ECR, S3, DynamoDB, IAM, CloudWatch, SecretsManager, ElastiCache, OpenSearchService

### Git Repository
- Main repo: `https://github.com/your-org/ai-ecommerce-devops`
- GitOps config in: `gitops-config/` directory

---

## AWS Account Setup

### 1. Create Dedicated Deployment User (Optional but Recommended)
```bash
aws iam create-user --user-name nexvion-deploy
aws iam attach-user-policy --user-name nexvion-deploy --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam create-access-key --user-name nexvion-deploy
# Save AccessKeyId and SecretAccessKey
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=ap-south-1
```

### 2. Verify Account Limits
```bash
# Check service quotas (request increases if needed)
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A  # vCPU
aws service-quotas get-service-quota --service-code rds --quota-code L-7934B8B2  # DB instances
aws service-quotas get-service-quota --service-code elasticloadbalancing --quota-code L-4F2B68E6  # ALBs
```

---

## State Backend Bootstrap

Run **once per AWS account** before any Terraform operations.

### 1. Create S3 Bucket for Terraform State
```bash
BUCKET_NAME="nexvion-terraform-state-$(aws sts get-caller-identity --query Account --output text)"
REGION="ap-south-1"

aws s3 mb "s3://${BUCKET_NAME}" --region "${REGION}"

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

# Enable server-side encryption
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### 2. Create DynamoDB Table for State Locking
```bash
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "${REGION}"

# Wait for table to be active
aws dynamodb wait table-exists --table-name terraform-locks --region "${REGION}"
```

### 3. Verify State Backend
```bash
cd terraform
cat > backend.hcl <<EOF
bucket         = "${BUCKET_NAME}"
key            = "prod/terraform.tfstate"
region         = "${REGION}"
dynamodb_table = "terraform-locks"
encrypt        = true
EOF

terraform init -backend-config=backend.hcl
```

---

## Secrets Configuration

All secrets stored in **AWS Secrets Manager**, synced to K8s via **ExternalSecrets Operator**.

### 1. Database Password
```bash
# Generate secure password
DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)

aws secretsmanager create-secret \
  --name nexvion/prod/db_password \
  --description "PostgreSQL password for production" \
  --secret-string "${DB_PASSWORD}" \
  --region ap-south-1

# Tag for cost allocation
aws secretsmanager tag-resource \
  --secret-id nexvion/prod/db_password \
  --tags Key=Environment,Value=production Key=Project,Value=nexvion
```

### 2. JWT Secret Key
```bash
JWT_SECRET=$(openssl rand -base64 48 | tr -d "=+/" | cut -c1-64)

aws secretsmanager create-secret \
  --name nexvion/prod/jwt_secret \
  --description "JWT signing secret for production" \
  --secret-string "${JWT_SECRET}" \
  --region ap-south-1
```

### 3. AI Analyzer API Keys
```bash
# Groq API Key (free tier available at console.groq.com)
aws secretsmanager create-secret \
  --name nexvion/prod/groq_api_key \
  --description "Groq API key for AI incident analysis" \
  --secret-string "gsk_..." \
  --region ap-south-1

# OpenAI API Key (fallback)
aws secretsmanager create-secret \
  --name nexvion/prod/openai_api_key \
  --description "OpenAI API key for AI incident analysis fallback" \
  --secret-string "sk-..." \
  --region ap-south-1
```

### 4. Slack Webhook for Alerts
```bash
# Create Slack App → Incoming Webhook → Copy URL
aws secretsmanager create-secret \
  --name nexvion/prod/slack_webhook \
  --description "Slack webhook for ArgoCD and AI alerts" \
  --secret-string "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX" \
  --region ap-south-1
```

### 5. ACM Certificate ARN
```bash
# Option A: Request via AWS Console (recommended)
# 1. Go to ACM in ap-south-1
# 2. Request public certificate for *.ghanshyam.site
# 3. Validate via DNS (Route53)
# 4. Copy ARN

# Option B: Request via CLI
CERT_ARN=$(aws acm request-certificate \
  --domain-name "*.ghanshyam.site" \
  --subject-alternative-names "ghanshyam.site" \
  --validation-method DNS \
  --region ap-south-1 \
  --query CertificateArn --output text)

# Wait for validation, then store
aws secretsmanager create-secret \
  --name nexvion/prod/certificate_arn \
  --description "ACM certificate ARN for ALB TLS" \
  --secret-string "${CERT_ARN}" \
  --region ap-south-1
```

### 6. Verify All Secrets
```bash
aws secretsmanager list-secrets \
  --filters Key=name,Values=nexvion/prod/ \
  --query 'SecretList[*].Name' --output table
```

---

## Infrastructure Deployment

### 1. Prepare Terraform Variables
```bash
cd terraform

# Copy example
cp terraform.tfvars.example environments/prod/terraform.tfvars

# Edit with your values
cat > environments/prod/terraform.tfvars <<EOF
# Required
aws_region           = "ap-south-1"
environment          = "prod"
project_name         = "nexvion"
key_pair_name        = "your-ec2-key-pair-name"

# Database (retrieved from Secrets Manager at runtime)
# db_password          = ""  # Don't store in tfvars!

# Certificate
certificate_arn      = ""  # Will be passed via -var

# VPC
vpc_cidr             = "10.0.0.0/16"
private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
public_subnet_cidrs  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# EKS
eks_version          = "1.28"
node_group_instance_types = ["t3.medium"]
node_group_desired_size   = 2
node_group_min_size       = 2
node_group_max_size       = 10

# RDS
db_instance_class      = "db.t3.medium"
db_allocated_storage   = 100
db_multi_az            = true
db_backup_retention    = 7

# Domain
domain_name            = "ghanshyam.site"
hosted_zone_id         = "ZXXXXXXXXXXXX"  # Get from Route53

# Monitoring
enable_monitoring      = true
grafana_admin_password = ""  # From Secrets Manager

# Cost optimization
use_spot_instances     = true
spot_instance_types    = ["t3.large", "t3.xlarge"]
EOF
```

### 2. Initialize Terraform
```bash
terraform init \
  -backend-config="bucket=${BUCKET_NAME}" \
  -backend-config="key=prod/terraform.tfstate" \
  -backend-config="region=ap-south-1" \
  -backend-config="dynamodb_table=terraform-locks" \
  -backend-config="encrypt=true"
```

### 3. Plan Deployment
```bash
# Get secrets for plan
DB_PASS=$(aws secretsmanager get-secret-value --secret-id nexvion/prod/db_password --query SecretString --output text)
CERT_ARN=$(aws secretsmanager get-secret-value --secret-id nexvion/prod/certificate_arn --query SecretString --output text)

terraform plan \
  -var-file=environments/prod/terraform.tfvars \
  -var="db_password=${DB_PASS}" \
  -var="certificate_arn=${CERT_ARN}" \
  -out=prod.tfplan
```

### 4. Apply Infrastructure
```bash
terraform apply prod.tfplan
```

**Expected Outputs to Save:**
```bash
# Save these for later steps
terraform output -json > /tmp/terraform-outputs.json

EKS_CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
ALB_DNS_NAME=$(terraform output -raw alb_dns_name)
ECR_FRONTEND_URL=$(terraform output -raw ecr_frontend_url)
ECR_BACKEND_URL=$(terraform output -raw ecr_backend_url)
ECR_AI_URL=$(terraform output -raw ecr_ai_analyzer_url)
```

### 4.1 Verify Infrastructure
```bash
# Check VPC
aws ec2 describe-vpcs --filters Name=tag:Name,Values=nexvion-prod-vpc

# Check EKS
aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --region ap-south-1

# Check RDS
aws rds describe-db-instances --db-instance-identifier nexvion-prod-db

# Check ALB
aws elbv2 describe-load-balancers --names nexvion-prod-alb
```

---

## Kubernetes Cluster Access

### 1. Update kubeconfig
```bash
aws eks update-kubeconfig \
  --name ${EKS_CLUSTER_NAME} \
  --region ap-south-1 \
  --alias nexvion-prod

# Verify context
kubectl config use-context nexvion-prod
kubectl config current-context
```

### 2. Verify Access
```bash
# Should show nodes
kubectl get nodes -o wide

# Should show system namespaces
kubectl get ns

# Check cluster version
kubectl version --short
```

### 3. Install AWS Load Balancer Controller (if not in Terraform)
```bash
# Create IAM policy
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json

# Create ServiceAccount with IRSA
eksctl create iamserviceaccount \
  --cluster=${EKS_CLUSTER_NAME} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve \
  --region ap-south-1

# Install via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${EKS_CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set image.repository=602401143452.dkr.ecr.ap-south-1.amazonaws.com/amazon/aws-load-balancer-controller \
  --version 1.7.0
```

---

## ArgoCD Installation

### 1. Install ArgoCD via Helm
```bash
# Add repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Create namespace
kubectl create namespace argocd

# Install with production values
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 6.5.0 \
  --set global.domain=argocd.ghanshyam.site \
  --set server.ingress.enabled=true \
  --set server.ingress.ingressClassName=alb \
  --set server.ingress.annotations."alb\.ingress\.kubernetes\.io/scheme"=internet-facing \
  --set server.ingress.annotations."alb\.ingress\.kubernetes\.io/target-type"=ip \
  --set server.ingress.annotations."alb\.ingress\.kubernetes\.io/certificate-arn"=${CERT_ARN} \
  --set server.ingress.annotations."alb\.ingress\.kubernetes\.io/ssl-policy"=ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --set server.ingress.annotations."alb\.ingress\.kubernetes\.io/listen-ports"='[{"HTTP": 80}, {"HTTPS": 443}]' \
  --set server.ingress.annotations."alb\.ingress\.kubernetes\.io/actions.ssl-redirect"='{"Type": "redirect", "RedirectConfig": { "Protocol": "HTTPS", "Port": "443", "StatusCode": "HTTP_301"}}' \
  --set configs.cm.application.instanceLabelKey=argocd.argoproj.io/instance \
  --set configs.cm.server.rbac.log.enforce.enable=true \
  --set configs.cm.server.statusbadge.enabled=true \
  --set dex.enabled=false \
  --set notifications.enabled=true \
  --set redis.enabled=true \
  --set redis-ha.enabled=false
```

### 2. Get Admin Password
```bash
# Wait for pods
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Get password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD Admin Password: ${ARGOCD_PASSWORD}"

# Login via CLI
argocd login argocd.ghanshyam.site --username admin --password "${ARGOCD_PASSWORD}" --insecure
```

### 3. Change Admin Password
```bash
argocd account update-password \
  --account admin \
  --current-password "${ARGOCD_PASSWORD}" \
  --new-password "your-secure-admin-password"
```

---

## GitOps Bootstrap

### 1. Apply ArgoCD Project & RBAC
```bash
# Project with destinations and source repos
kubectl apply -f gitops-config/argocd/projects/nexvion-project.yaml

# RBAC ConfigMap
kubectl apply -f gitops-config/argocd/config/argocd-rbac-cm.yaml

# Notifications ConfigMap (Slack)
kubectl apply -f gitops-config/argocd/config/argocd-notifications-cm.yaml

# Slack token secret
kubectl apply -f gitops-config/argocd/config/argocd-slack-secret.yaml

# ArgoCD Ingress
kubectl apply -f gitops-config/argocd/config/argocd-ingress.yaml

# ExternalSecrets RBAC
kubectl apply -f gitops-config/argocd/config/external-secrets-rbac.yaml
```

### 2. Install ExternalSecrets Operator
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets-system \
  --create-namespace \
  --version 0.9.0 \
  --set installCRDs=true

# Wait for CRDs
kubectl wait --for=condition=Established crd/clustersecretstores.external-secrets.io --timeout=60s
kubectl wait --for=condition=Established crd/externalsecrets.external-secrets.io --timeout=60s
```

### 3. Configure ExternalSecrets (AWS Secrets Manager)
```bash
# Create ClusterSecretStore
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-south-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets-system
EOF

# Create ServiceAccount with IRSA for ExternalSecrets
eksctl create iamserviceaccount \
  --cluster=${EKS_CLUSTER_NAME} \
  --namespace=external-secrets-system \
  --name=external-secrets-sa \
  --attach-policy-arn=arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/SecretsManagerReadWrite \
  --approve \
  --region ap-south-1
```

### 4. Apply Application Manifests
```bash
# Apply in order: monitoring, logging, then apps
kubectl apply -f gitops-config/argocd/applications/monitoring.yaml
kubectl apply -f gitops-config/argocd/applications/logging.yaml
kubectl apply -f gitops-config/argocd/applications/nexvion-dev.yaml
kubectl apply -f gitops-config/argocd/applications/nexvion-staging.yaml
kubectl apply -f gitops-config/argocd/applications/nexvion-prod.yaml

# Verify applications created
argocd app list
```

---

## Container Images

### 1. ECR Login
```bash
# Get login token
aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS --password-stdin $(aws sts get-caller-identity --query Account --output text).dkr.ecr.ap-south-1.amazonaws.com
```

### 2. Build & Push Multi-Arch Images (Recommended)
```bash
# Enable buildx
docker buildx create --name nexvion-builder --use --bootstrap

# Build and push frontend
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ${ECR_FRONTEND_URL}:v1.0.0 \
  -t ${ECR_FRONTEND_URL}:latest \
  --push ./frontend

# Build and push backend
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ${ECR_BACKEND_URL}:v1.0.0 \
  -t ${ECR_BACKEND_URL}:latest \
  --push ./backend

# Build and push AI analyzer
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ${ECR_AI_URL}:v1.0.0 \
  -t ${ECR_AI_URL}:latest \
  --push ./ai/incident-analysis
```

### 3. Verify Images in ECR
```bash
aws ecr describe-images --repository-name nexvion-frontend --region ap-south-1
aws ecr describe-images --repository-name nexvion-backend --region ap-south-1
aws ecr describe-images --repository-name nexvion-ai-analyzer --region ap-south-1
```

### 4. Scan Images with Trivy
```bash
# Install trivy
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

# Scan images
trivy image --severity HIGH,CRITICAL ${ECR_FRONTEND_URL}:v1.0.0
trivy image --severity HIGH,CRITICAL ${ECR_BACKEND_URL}:v1.0.0
trivy image --severity HIGH,CRITICAL ${ECR_AI_URL}:v1.0.0
```

---

## Application Deployment

### 1. Update Kustomize Overlays with Image Tags
```bash
cd gitops-config/overlays/prod

# Update image references
kustomize edit set image nexvion-frontend=${ECR_FRONTEND_URL}:v1.0.0
kustomize edit set image nexvion-backend=${ECR_BACKEND_URL}:v1.0.0
kustomize edit set image nexvion-ai-analyzer=${ECR_AI_URL}:v1.0.0

# Verify
kustomize build . | grep -E "(image:|name: nexvion)"
```

### 2. Commit & Push Kustomize Changes
```bash
git add gitops-config/overlays/prod/kustomization.yaml
git commit -m "chore: update production images to v1.0.0"
git push origin main
```

### 3. Sync via ArgoCD
```bash
# Option A: CLI
argocd app sync nexvion-prod --prune

# Option B: UI - Click SYNC button on nexvion-prod application

# Wait for healthy
argocd app wait nexvion-prod --health --timeout 300
```

### 4. Monitor Deployment
```bash
# Watch pods
kubectl get pods -n nexvion -w

# Check rollout status
kubectl rollout status deployment/nexvion-backend -n nexvion --timeout=300s
kubectl rollout status deployment/nexvion-frontend -n nexvion --timeout=300s
kubectl rollout status deployment/nexvion-ai-analyzer -n nexvion --timeout=300s

# Check events
kubectl get events -n nexvion --sort-by='.lastTimestamp'
```

---

## DNS & SSL Configuration

### 1. Verify ALB DNS Name
```bash
# From Terraform output
ALB_DNS=$(terraform output -raw alb_dns_name)
echo "ALB DNS: ${ALB_DNS}"
```

### 2. Create Route53 Records
```bash
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name ghanshyam.site --query "HostedZones[0].Id" --output text | cut -d'/' -f3)

# Frontend (apex + www)
aws route53 change-resource-record-sets \
  --hosted-zone-id ${HOSTED_ZONE_ID} \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "nexvion.ghanshyam.site",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "'"$(aws elbv2 describe-load-balancers --names nexvion-prod-alb --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)"'",
          "DNSName": "'"${ALB_DNS}"'",
          "EvaluateTargetHealth": true
        }
      }
    }]
  }'

# ArgoCD subdomain
aws route53 change-resource-record-sets \
  --hosted-zone-id ${HOSTED_ZONE_ID} \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "argocd.ghanshyam.site",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "'"$(aws elbv2 describe-load-balancers --names nexvion-prod-alb --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)"'",
          "DNSName": "'"${ALB_DNS}"'",
          "EvaluateTargetHealth": true
        }
      }
    }]
  }'
```

### 3. Verify DNS Propagation
```bash
# Wait for DNS propagation
dig nexvion.ghanshyam.site +short
dig argocd.ghanshyam.site +short

# Should return ALB IP addresses
```

### 4. Test HTTPS
```bash
# Test frontend
curl -I https://nexvion.ghanshyam.site
# Should return 200 OK with security headers

# Test API
curl https://nexvion.ghanshyam.site/api/health
# Should return JSON with status: "healthy"

# Test ArgoCD
curl -I https://argocd.ghanshyam.site
```

---

## Post-Deployment Verification

### 1. Health Checks
```bash
# Backend health
curl -s https://nexvion.ghanshyam.site/api/health | jq .

# Expected:
# {
#   "status": "healthy",
#   "version": "0.1.0",
#   "database": "connected"
# }

# Detailed health
curl -s https://nexvion.ghanshyam.site/api/health/detailed | jq .

# Frontend
curl -s -o /dev/null -w "%{http_code}" https://nexvion.ghanshyam.site
# Should return 200
```

### 2. Functional Tests
```bash
# Test product listing
curl -s https://nexvion.ghanshyam.site/api/products | jq '.total'

# Test categories
curl -s https://nexvion.ghanshyam.site/api/products/categories | jq .

# Test order creation
curl -X POST https://nexvion.ghanshyam.site/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "user_name": "Test User",
    "user_email": "test@example.com",
    "phone": "9876543210",
    "address": "123 Test St",
    "city": "Test City",
    "pin_code": "123456",
    "payment_method": "cod",
    "items": [{"product_id": 1, "quantity": 1}]
  }' | jq .
```

### 3. AI Analyzer Verification
```bash
# Check AI analyzer pod
kubectl logs -n nexvion -l app.kubernetes.io/component=ai-analyzer --tail=50

# Manual trigger
kubectl exec -n nexvion deployment/nexvion-ai-analyzer -- python analyzer.py --once
```

### 4. Monitoring Verification
```bash
# Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &
open http://localhost:9090/targets

# Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80 &
open http://localhost:3000
# admin / (from secrets)

# Loki
kubectl port-forward -n logging svc/loki 3100:3100 &
# Test query: {namespace="nexvion"} |~ "ERROR"
```

### 5. Security Verification
```bash
# NetworkPolicies
kubectl get networkpolicies -n nexvion

# PodSecurityStandards
kubectl get ns nexvion -o yaml | grep -A5 pod-security

# ExternalSecrets sync
kubectl get externalsecrets -n nexvion
kubectl get secrets -n nexvion | grep -E "(db|jwt|groq|openai)"

# RBAC
kubectl auth can-i create deployments --as=system:serviceaccount:nexvion:nexvion-backend
```

---

## Rollback Procedure

### 1. Quick Rollback (ArgoCD)
```bash
# Option A: CLI - Rollback to previous revision
argocd app rollback nexvion-prod <REVISION_NUMBER>

# Option B: UI - Click ROLLBACK on application

# Option C: Git revert (recommended for GitOps)
git log --oneline -10
git revert <COMMIT_SHA>
git push origin main
# ArgoCD auto-syncs within 3 min
```

### 2. Image Rollback
```bash
# Get previous image tag
aws ecr describe-images --repository-name nexvion-backend --region ap-south-1 --query 'imageDetails[*].imageTags' --output text

# Update kustomize to previous tag
cd gitops-config/overlays/prod
kustomize edit set image nexvion-backend=${ECR_BACKEND_URL}:v0.9.0
git add kustomization.yaml
git commit -m "chore: rollback backend to v0.9.0"
git push origin main

# ArgoCD syncs automatically
argocd app sync nexvion-prod
```

### 3. Database Rollback (RDS)
```bash
# List available snapshots
aws rds describe-db-snapshots --db-instance-identifier nexvion-prod-db --snapshot-type automated --query 'DBSnapshots[*].[DBSnapshotIdentifier,SnapshotCreateTime]' --output table

# Restore to point in time
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier nexvion-prod-db \
  --target-db-instance-identifier nexvion-prod-db-restored \
  --restore-time 2026-10-09T10:00:00Z \
  --region ap-south-1

# Update DNS/Secret to point to restored instance
```

### 4. Full Cluster Rollback (Terraform)
```bash
# Destroy and recreate (last resort)
terraform destroy -var-file=environments/prod/terraform.tfvars -var="db_password=${DB_PASS}" -var="certificate_arn=${CERT_ARN}"

# Re-apply
terraform apply -var-file=environments/prod/terraform.tfvars -var="db_password=${DB_PASS}" -var="certificate_arn=${CERT_ARN}"
```

---

## Monitoring & Alerting Setup

### 1. Grafana Dashboards Import
```bash
# Port forward
kubectl port-forward -n monitoring svc/grafana 3000:80 &

# Login: admin / (from secret)
GRAFANA_PASS=$(aws secretsmanager get-secret-value --secret-id nexvion/prod/grafana_admin_password --query SecretString --output text)

# Import dashboards via API or UI:
# - Kubernetes Cluster (ID: 315)
# - Node Exporter Full (ID: 1860)
# - Kubernetes Pods (ID: 6417)
# - FastAPI Application (custom)
# - Business Metrics (custom)
```

### 2. Alert Rules Verification
```bash
# Check PrometheusRules
kubectl get prometheusrules -n monitoring

# Key alerts to verify:
# - KubePodCrashLooping
# - KubeDeploymentReplicasMismatch
# - KubeNodeNotReady
# - HighErrorRate
# - HighLatency
# - DiskSpaceWarning
# - AIAnalyzerFailed
```

### 3. Slack Notification Test
```bash
# Trigger test alert
kubectl -n monitoring exec -it prometheus-0 -- \
  amtool alert add test_alert severity=critical instance=test alertname=TestAlert

# Verify Slack receives notification
# Check Alertmanager logs
kubectl logs -n monitoring -l app=alertmanager
```

### 4. AI Analyzer Alert Test
```bash
# Generate test error logs
kubectl exec -n nexvion deployment/nexvion-backend -- \
  python -c "import logging; logging.error('Connection refused to database: postgres:5432')"

# Wait for AI analyzer run (15 min) or trigger manually
kubectl exec -n nexvion deployment/nexvion-ai-analyzer -- python analyzer.py --once

# Check Slack for incident report
```

---

## Maintenance Windows

### Scheduled Maintenance
```bash
# Weekly: Sunday 02:00-04:00 IST
# - Node patching (rolling update)
# - Dependency updates
# - Security scans

# Monthly: First Sunday 01:00-05:00 IST
# - RDS minor version upgrade
# - EKS version upgrade (quarterly)
# - Certificate renewal check
```

### Pre-Maintenance Checklist
- [ ] Notify stakeholders 48h in advance
- [ ] Verify backup completion
- [ ] Check current deployment status
- [ ] Prepare rollback plan
- [ ] Schedule maintenance window in PagerDuty

---

## Troubleshooting Quick Reference

| Symptom | Check | Command |
|---------|-------|---------|
| Pods not starting | Events, Resources | `kubectl describe pod -n nexvion <pod>` |
| 502/503 errors | ALB targets | `aws elbv2 describe-target-health --target-group-arn <arn>` |
| DB connection failed | Secrets, SG | `kubectl logs -n nexvion deploy/backend` |
| ArgoCD OutOfSync | Resource diff | `argocd app diff nexvion-prod` |
| High latency | Metrics | `kubectl top pods -n nexvion` |
| OOM kills | Events | `kubectl get events -n nexvion --field-selector reason=OOMKilling` |
| AI analyzer failing | Logs | `kubectl logs -n nexvion deploy/ai-analyzer` |

---

## Support Contacts

| Role | Contact | Escalation |
|------|---------|------------|
| Platform Team | #nexvion-platform | PagerDuty |
| On-Call Engineer | Rotation schedule | PagerDuty |
| AWS Support | Business Support | Console → Support Center |
| ArgoCD Issues | GitHub Discussions | - |
| ExternalSecrets | CNCF Slack #external-secrets | - |

---

## Appendix: Useful Commands

```bash
# View all resources in namespace
kubectl get all -n nexvion

# View resource usage
kubectl top pods -n nexvion --containers

# Check certificate expiry
kubectl get cert -n nexvion -o yaml | grep -A2 notAfter

# Force ExternalSecrets sync
kubectl annotate externalsecret -n nexvion --all force-sync=$(date +%s) --overwrite

# Debug networking
kubectl run -it --rm debug --image=nicolaka/netshoot -- nslookup nexvion-backend.nexvion.svc.cluster.local

# Check HPA status
kubectl get hpa -n nexvion

# View ArgoCD application resources
argocd app resources nexvion-prod

# Export all K8s resources for backup
kubectl get all,configmap,secret,pvc,ingress -n nexvion -o yaml > nexvion-backup-$(date +%Y%m%d).yaml
```