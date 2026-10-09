#!/bin/bash
set -euo pipefail

# Nexvion E-Commerce Platform - Cleanup Script
# WARNING: This destroys ALL AWS resources!

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

confirm() {
    echo -e "${RED}⚠️  WARNING: This will DESTROY all AWS resources!${NC}"
    echo "This includes:"
    echo "  - EKS Cluster and all workloads"
    echo "  - EC2 PostgreSQL instance"
    echo "  - VPC, Subnets, NAT Gateways, ALB"
    echo "  - Route53 records"
    echo "  - ECR repositories and images"
    echo ""
    read -p "Type 'DESTROY' to confirm: " confirmation
    if [[ "$confirmation" != "DESTROY" ]]; then
        log_error "Confirmation failed. Aborting."
        exit 1
    fi
}

cleanup_kubernetes() {
    log_info "Cleaning up Kubernetes resources..."
    cd "$PROJECT_ROOT"
    if aws eks describe-cluster --name nexvion-cluster --region ap-south-1 &>/dev/null; then
        aws eks update-kubeconfig --name nexvion-cluster --region ap-south-1
        helm uninstall nexvion -n nexvion --wait 2>/dev/null || true
        kubectl delete namespace nexvion --wait 2>/dev/null || true
        log_success "Kubernetes resources cleaned up"
    else
        log_info "EKS cluster not found, skipping Kubernetes cleanup"
    fi
}

cleanup_terraform() {
    log_info "Destroying Terraform infrastructure..."
    cd "$PROJECT_ROOT/terraform"
    if [[ -f "terraform.tfvars" ]]; then
        terraform destroy -auto-approve
        log_success "Terraform infrastructure destroyed"
    else
        log_warn "terraform.tfvars not found, skipping Terraform destroy"
    fi
}

cleanup_ecr() {
    log_info "Cleaning up ECR repositories..."
    aws ecr describe-repositories --repository-names nexvion-frontend --region ap-south-1 &>/dev/null && \
        aws ecr delete-repository --repository-name nexvion-frontend --force --region ap-south-1 || true
    aws ecr describe-repositories --repository-names nexvion-backend --region ap-south-1 &>/dev/null && \
        aws ecr delete-repository --repository-name nexvion-backend --force --region ap-south-1 || true
    log_success "ECR repositories cleaned up"
}

cleanup_local() {
    log_info "Cleaning up local Docker resources..."
    cd "$PROJECT_ROOT"
    docker compose down -v --remove-orphans
    docker system prune -f
    log_success "Local resources cleaned up"
}

case "${1:-all}" in
    kubernetes|k8s)
        cleanup_kubernetes
        ;;
    terraform)
        confirm
        cleanup_terraform
        ;;
    ecr)
        cleanup_ecr
        ;;
    local)
        cleanup_local
        ;;
    all)
        confirm
        cleanup_kubernetes
        cleanup_terraform
        cleanup_ecr
        log_success "All cleanup complete!"
        ;;
    *)
        echo "Usage: $0 [kubernetes|terraform|ecr|local|all]"
        exit 1
        ;;
esac