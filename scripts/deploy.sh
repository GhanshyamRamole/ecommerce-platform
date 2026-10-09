#!/bin/bash
set -euo pipefail

# Nexvion E-Commerce Platform - Deployment Script
# Usage: ./scripts/deploy.sh [local|dev|staging|production|terraform|kubernetes]

ENVIRONMENT="${1:-local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_prerequisites() {
    local missing=()
    for cmd in docker docker-compose aws kubectl helm terraform; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

# Environment-specific configuration
get_env_config() {
    case "$ENVIRONMENT" in
        dev)
            echo "dev nexvion-dev nexvion-dev-cluster ap-south-1 values-dev.yaml https://nexvion-dev.ghanshyam.site nexvion dev-latest"
            ;;
        staging)
            echo "staging nexvion-staging nexvion-staging-cluster ap-south-1 values-staging.yaml https://staging-nexvion.ghanshyam.site nexvion staging-latest"
            ;;
        production|prod)
            echo "prod nexvion nexvion-prod-cluster ap-south-1 values-prod.yaml https://nexvion.ghanshyam.site nexvion prod-latest"
            ;;
        *)
            echo "prod nexvion nexvion-prod-cluster ap-south-1 values-prod.yaml https://nexvion.ghanshyam.site nexvion prod-latest"
            ;;
    esac
}

get_tfvars_file() {
    case "$ENVIRONMENT" in
        dev)
            echo "environments/dev/terraform.tfvars"
            ;;
        staging)
            echo "environments/staging/terraform.tfvars"
            ;;
        production|prod)
            echo "environments/prod/terraform.tfvars"
            ;;
        *)
            echo "terraform.tfvars"
            ;;
    esac
}

# Read environment configuration
read -r ENV_SUFFIX NAMESPACE CLUSTER_NAME AWS_REGION VALUES_FILE APP_URL ECR_REPOSITORY IMAGE_TAG <<< "$(get_env_config)"
RELEASE_NAME="nexvion-${ENV_SUFFIX}"

# Derive ECR registry from AWS account
ECR_REGISTRY=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [[ -n "$ECR_REGISTRY" ]]; then
    ECR_REGISTRY="${ECR_REGISTRY}.dkr.ecr.${AWS_REGION}.amazonaws.com"
else
    log_warn "Could not determine AWS account ID, ECR_REGISTRY not set"
fi

deploy_local() {
    log_info "Starting local deployment with Docker Compose..."
    cd "$PROJECT_ROOT"
    docker compose up --build -d
    log_info "Waiting for services to be healthy..."
    sleep 10
    docker compose exec backend python -m app.db.init_db
    log_success "Local deployment complete!"
    log_info "Frontend: http://localhost:8080"
    log_info "Backend API: http://localhost:8000"
    log_info "API Docs: http://localhost:8000/docs"
}

deploy_terraform() {
    local tfvars_file=$(get_tfvars_file)
    local backend_config="environments/${ENVIRONMENT}/backend.hcl"
    log_info "Deploying infrastructure with Terraform (using $tfvars_file)..."
    cd "$PROJECT_ROOT/terraform"

    if [[ ! -f "$tfvars_file" ]]; then
        log_error "Terraform variables file not found: $tfvars_file"
        log_info "Available environments: dev, staging, prod"
        exit 1
    fi

    if [[ ! -f "$backend_config" ]]; then
        log_error "Backend config file not found: $backend_config"
        exit 1
    fi

    # Initialize with environment-specific backend config
    terraform init -backend-config="$backend_config"
    terraform plan -var-file="$tfvars_file" -out=tfplan
    terraform apply tfplan

    log_success "Infrastructure deployed!"
    terraform output -json > "$PROJECT_ROOT/terraform-outputs.json"
}

deploy_kubernetes() {
    log_info "Deploying to EKS with Kustomize (environment: $ENVIRONMENT)..."
    cd "$PROJECT_ROOT"

    # Get outputs from Terraform
    log_info "Getting Terraform outputs..."
    POSTGRES_IP=$(cd "$PROJECT_ROOT/terraform" && terraform output -raw postgres_endpoint 2>/dev/null || echo "")
    if [[ -z "$POSTGRES_IP" || "$POSTGRES_IP" == "null" ]]; then
        log_error "Could not get postgres_endpoint from Terraform"
        exit 1
    fi
    TF_CLUSTER_NAME=$(cd "$PROJECT_ROOT/terraform" && terraform output -raw eks_cluster_name 2>/dev/null || echo "")
    if [[ -n "$TF_CLUSTER_NAME" && "$TF_CLUSTER_NAME" != "null" ]]; then
        CLUSTER_NAME="$TF_CLUSTER_NAME"
    fi

    # Update kubeconfig
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

    # Create namespace
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Create ECR secret if needed
    if [[ -n "${ECR_REGISTRY:-}" ]]; then
        kubectl create secret docker-registry ecr-secret \
            --docker-server="$ECR_REGISTRY" \
            --docker-username=AWS \
            --docker-password="$(aws ecr get-login-password --region "$AWS_REGION")" \
            --namespace "$NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi

    # Check for required environment variables
    if [[ -z "${DB_PASSWORD:-}" ]]; then
        log_error "DB_PASSWORD environment variable is required"
        exit 1
    fi
    if [[ -z "${JWT_SECRET_KEY:-}" ]]; then
        log_error "JWT_SECRET_KEY environment variable is required"
        exit 1
    fi

    # Deploy with Kustomize
    cd "$PROJECT_ROOT/gitops-config/overlays/$ENV_SUFFIX"
    kustomize edit set image nexvion-frontend=${ECR_REGISTRY}/${ECR_REPOSITORY}-frontend:${IMAGE_TAG:-latest}
    kustomize edit set image nexvion-backend=${ECR_REGISTRY}/${ECR_REPOSITORY}-backend:${IMAGE_TAG:-latest}
    kustomize edit set image nexvion-ai-analyzer=${ECR_REGISTRY}/${ECR_REPOSITORY}-ai-analyzer:${IMAGE_TAG:-latest}
    kustomize build . | kubectl apply -f -

    log_success "Application deployed to EKS!"

    # Get ingress URL
    INGRESS_HOST=$(kubectl get ingress nexvion-frontend -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    if [[ -n "$INGRESS_HOST" ]]; then
        log_info "Application URL: https://${INGRESS_HOST}"
    else
        log_info "Application URL: ${APP_URL}"
    fi
}

verify_deployment() {
    log_info "Verifying deployment..."
    local url="${1:-${APP_URL}}"

    log_info "Checking frontend health..."
    if curl -sf "$url/health" > /dev/null; then
        log_success "Frontend health check passed"
    else
        log_error "Frontend health check failed"
        return 1
    fi

    log_info "Checking backend health..."
    if curl -sf "$url/api/health" > /dev/null; then
        log_success "Backend health check passed"
    else
        log_error "Backend health check failed"
        return 1
    fi

    log_info "Checking API products endpoint..."
    if curl -sf "$url/api/products" | jq -e '.total > 0' > /dev/null; then
        log_success "Products API working"
    else
        log_error "Products API not returning data"
        return 1
    fi

    log_success "All health checks passed!"
}

case "$ENVIRONMENT" in
    local)
        check_prerequisites
        deploy_local
        ;;
    dev)
        check_prerequisites
        deploy_terraform
        deploy_kubernetes
        verify_deployment "$APP_URL"
        ;;
    terraform)
        check_prerequisites
        deploy_terraform
        ;;
    kubernetes|k8s)
        check_prerequisites
        deploy_kubernetes
        ;;
    production|prod)
        check_prerequisites
        deploy_terraform
        deploy_kubernetes
        verify_deployment "$APP_URL"
        ;;
    staging)
        check_prerequisites
        deploy_terraform
        deploy_kubernetes
        verify_deployment "$APP_URL"
        ;;
    *)
        log_error "Unknown environment: $ENVIRONMENT"
        echo "Usage: $0 [local|dev|staging|production|terraform|kubernetes]"
        exit 1
        ;;
esac