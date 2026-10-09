#!/bin/bash
set -euo pipefail

# ArgoCD Bootstrap Script
# Installs ArgoCD and deploys Nexvion infrastructure + applications

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
GITOPS_DIR="$PROJECT_ROOT/gitops-config"
OBSERVABILITY_DIR="$PROJECT_ROOT/observability-infra"

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
    log_info "Checking prerequisites..."
    local missing=()
    for cmd in kubectl helm aws argocd; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_info "Install argocd CLI: curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 && chmod +x /usr/local/bin/argocd"
        exit 1
    fi
    log_success "All prerequisites found"
}

install_argocd() {
    log_info "Installing ArgoCD..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    log_info "Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-repo-server -n argocd
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-application-controller -n argocd
    
    log_success "ArgoCD installed"
}

configure_argocd() {
    log_info "Configuring ArgoCD..."
    
    # Apply RBAC config
    kubectl apply -f "$GITOPS_DIR/argocd/config/argocd-rbac-cm.yaml"
    
    # Apply ArgoCD ConfigMap
    kubectl apply -f "$GITOPS_DIR/argocd/config/argocd-cm.yaml"
    
    # Apply Notifications ConfigMap
    kubectl apply -f "$GITOPS_DIR/argocd/config/argocd-notifications-cm.yaml"
    
    # Apply Slack secret
    kubectl apply -f "$GITOPS_DIR/argocd/config/argocd-slack-secret.yaml"
    
    # Apply Ingress
    kubectl apply -f "$GITOPS_DIR/argocd/config/argocd-ingress.yaml"
    
    # Restart ArgoCD server to pick up config changes
    kubectl rollout restart deployment/argocd-server -n argocd
    kubectl rollout restart deployment/argocd-repo-server -n argocd
    
    log_success "ArgoCD configured"
}

install_external_secrets() {
    log_info "Installing External Secrets Operator..."
    
    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update
    
    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace external-secrets-system \
        --create-namespace \
        --version 0.14.1 \
        --wait --timeout 5m
    
    # Apply RBAC for External Secrets
    kubectl apply -f "$GITOPS_DIR/argocd/config/external-secrets-rbac.yaml"
    
    log_success "External Secrets Operator installed"
}

deploy_infrastructure() {
    log_info "Deploying Observability Infrastructure..."
    
    # Add Helm repos
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo update
    
    # Deploy Monitoring (Prometheus, Grafana, Alertmanager, Node Exporter)
    log_info "Deploying Monitoring Stack..."
    helm upgrade --install monitoring "$OBSERVABILITY_DIR/helm/monitoring" \
        --namespace monitoring \
        --create-namespace \
        -f "$OBSERVABILITY_DIR/helm/monitoring/values.yaml" \
        --wait --timeout 10m
    
    # Deploy Logging (Loki + Promtail)
    log_info "Deploying Logging Stack..."
    helm upgrade --install logging "$OBSERVABILITY_DIR/helm/logging" \
        --namespace monitoring \
        --create-namespace \
        -f "$OBSERVABILITY_DIR/helm/logging/values.yaml" \
        --wait --timeout 10m
    
    log_success "Observability infrastructure deployed"
}

deploy_argocd_apps() {
    log_info "Deploying ArgoCD Applications..."
    
    # Apply Project first
    kubectl apply -f "$GITOPS_DIR/argocd/projects/nexvion-project.yaml"
    
    # Apply Infrastructure Applications
    kubectl apply -f "$OBSERVABILITY_DIR/argocd/applications/monitoring.yaml"
    kubectl apply -f "$OBSERVABILITY_DIR/argocd/applications/logging.yaml"
    
    # Apply Application Applications
    kubectl apply -f "$GITOPS_DIR/argocd/applications/nexvion-dev.yaml"
    kubectl apply -f "$GITOPS_DIR/argocd/applications/nexvion-staging.yaml"
    kubectl apply -f "$GITOPS_DIR/argocd/applications/nexvion-prod.yaml"
    
    log_success "ArgoCD Applications deployed"
}

initial_sync() {
    log_info "Performing initial sync for monitoring..."
    argocd app sync monitoring --prune
    
    log_info "Waiting for monitoring sync to complete..."
    argocd app wait monitoring --health --timeout=300
    
    log_info "Performing initial sync for logging..."
    argocd app sync logging --prune
    
    log_info "Waiting for logging sync to complete..."
    argocd app wait logging --health --timeout=300
    
    log_info "Performing initial sync for dev environment..."
    argocd app sync nexvion-dev --prune
    
    log_info "Waiting for dev sync to complete..."
    argocd app wait nexvion-dev --health --timeout=300
    
    log_success "Initial sync completed"
}

get_argocd_password() {
    log_info "Getting ArgoCD admin password..."
    local password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    echo "ArgoCD Admin Password: $password"
}

print_summary() {
    echo ""
    echo "=========================================="
    echo "ArgoCD + Observability Bootstrap Complete!"
    echo "=========================================="
    echo ""
    echo "ArgoCD URL: https://argocd.ghanshyam.site"
    echo "Grafana URL: https://grafana.nexvion.ghanshyam.site"
    echo "Admin User: admin"
    get_argocd_password
    echo ""
    echo "Applications:"
    echo "  Infrastructure:"
    echo "    - monitoring (auto-sync enabled)"
    echo "    - logging (auto-sync enabled)"
    echo "  Applications:"
    echo "    - nexvion-dev (auto-sync enabled)"
    echo "    - nexvion-staging (auto-sync enabled)"
    echo "    - nexvion-prod (manual sync required)"
    echo ""
    echo "Next Steps:"
    echo "  1. Configure SSO/OIDC in argocd-rbac-cm.yaml"
    echo "  2. Update certificate ARNs in ingress files"
    echo "  3. Create AWS Secrets Manager secrets for each environment"
    echo "  4. Update GITOPS_REPO in GitHub Actions workflow"
    echo "  5. Add GITOPS_BOT_TOKEN to GitHub secrets"
    echo "  6. Create S3 bucket 'nexvion-loki-logs' in ap-south-1"
    echo "  7. Create ACM certificates for grafana.nexvion.ghanshyam.site"
    echo "  8. Add SLACK_WEBHOOK_URL to GitHub secrets"
    echo "  9. Trigger CI pipeline to test GitOps flow"
    echo ""
}

main() {
    log_info "=== ArgoCD + Observability Bootstrap for Nexvion ==="
    
    check_prerequisites
    install_argocd
    configure_argocd
    install_external_secrets
    deploy_infrastructure
    deploy_argocd_apps
    initial_sync
    print_summary
}

main "$@"