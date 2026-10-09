#!/bin/bash
set -euo pipefail

# Nexvion E-Commerce Platform - Health Check Script
# Checks health of all services locally and in production

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_local() {
    log_info "=== Local Docker Compose Health Check ==="
    cd "$PROJECT_ROOT"
    
    local all_healthy=true
    
    # Check Docker Compose services
    log_info "Checking Docker Compose services..."
    if docker compose ps --format json 2>/dev/null | jq -e 'all(.[]; .State == "running")' > /dev/null 2>&1; then
        log_success "Docker Compose is running"
    else
        log_error "Docker Compose services not running"
        docker compose ps
        all_healthy=false
    fi
    
    # Check PostgreSQL
    log_info "Checking PostgreSQL..."
    if docker compose exec -T postgres pg_isready -U postgres > /dev/null 2>&1; then
        log_success "PostgreSQL is healthy"
    else
        log_error "PostgreSQL health check failed"
        all_healthy=false
    fi
    
    # Check Backend
    log_info "Checking Backend API..."
    if curl -sf http://localhost:8000/api/health > /dev/null; then
        local backend_health=$(curl -s http://localhost:8000/api/health)
        local db_status=$(echo "$backend_health" | jq -r '.database')
        if [[ "$db_status" == "connected" ]]; then
            log_success "Backend is healthy (DB: connected)"
        else
            log_warn "Backend responding but DB status: $db_status"
        fi
    else
        log_error "Backend health check failed"
        all_healthy=false
    fi
    
    # Check Backend Detailed Health
    log_info "Checking Backend Detailed Health..."
    if curl -sf http://localhost:8000/api/health/detailed > /dev/null; then
        local detailed=$(curl -s http://localhost:8000/api/health/detailed)
        local status=$(echo "$detailed" | jq -r '.status')
        log_success "Backend detailed health: $status"
        echo "$detailed" | jq .
    else
        log_warn "Backend detailed health endpoint not responding"
    fi
    
    # Check Frontend
    log_info "Checking Frontend..."
    if curl -sf http://localhost:8080/health > /dev/null; then
        log_success "Frontend is healthy"
    else
        log_error "Frontend health check failed"
        all_healthy=false
    fi
    
    # Check OpenSearch (if running)
    log_info "Checking OpenSearch..."
    if curl -sf http://localhost:9200/_cluster/health > /dev/null 2>&1; then
        local os_health=$(curl -s http://localhost:9200/_cluster/health)
        local status=$(echo "$os_health" | jq -r '.status')
        log_success "OpenSearch status: $status"
    else
        log_warn "OpenSearch not responding (may not be running)"
    fi
    
    # Check AI Analyzer (if running)
    log_info "Checking AI Analyzer..."
    if docker compose ps ai-analyzer --format json 2>/dev/null | jq -e 'all(.[]; .State == "running")' > /dev/null 2>&1; then
        log_success "AI Analyzer container is running"
    else
        log_warn "AI Analyzer not running (optional service)"
    fi
    
    if [[ "$all_healthy" == "true" ]]; then
        log_success "=== All local services healthy ==="
        return 0
    else
        log_error "=== Some local services unhealthy ==="
        return 1
    fi
}

check_kubernetes() {
    local namespace="${1:-nexvion}"
    local context="${2:-}"
    
    log_info "=== Kubernetes Health Check (namespace: $namespace) ==="
    
    if [[ -n "$context" ]]; then
        kubectl config use-context "$context"
    fi
    
    local all_healthy=true
    
    # Check namespace exists
    if ! kubectl get namespace "$namespace" > /dev/null 2>&1; then
        log_error "Namespace $namespace not found"
        return 1
    fi
    
    # Check pods
    log_info "Checking pod status..."
    local pods=$(kubectl get pods -n "$namespace" -o json)
    local total_pods=$(echo "$pods" | jq '.items | length')
    local ready_pods=$(echo "$pods" | jq '[.items[] | select(.status.phase == "Running" and (.status.conditions[]? | select(.type == "Ready" and .status == "True")))] | length')
    
    if [[ "$total_pods" -eq "$ready_pods" && "$total_pods" -gt 0 ]]; then
        log_success "All $total_pods pods are Ready"
    else
        log_warn "$ready_pods/$total_pods pods Ready"
        kubectl get pods -n "$namespace" -o wide
        all_healthy=false
    fi
    
    # Check deployments
    log_info "Checking deployment status..."
    kubectl get deployments -n "$namespace"
    
    # Check services
    log_info "Checking services..."
    kubectl get svc -n "$namespace"
    
    # Check ingress
    log_info "Checking ingress..."
    kubectl get ingress -n "$namespace"
    
    # Check HPA
    log_info "Checking HPA..."
    kubectl get hpa -n "$namespace"
    
    # Check NetworkPolicies
    log_info "Checking NetworkPolicies..."
    kubectl get networkpolicy -n "$namespace"
    
    # Test backend health via service
    log_info "Testing backend health via service..."
    if kubectl run --rm -i --restart=Never health-check --image=curlimages/curl:latest -n "$namespace" -- \
        curl -sf http://nexvion-backend:8000/api/health > /dev/null 2>&1; then
        log_success "Backend service health check passed"
    else
        log_error "Backend service health check failed"
        all_healthy=false
    fi
    
    # Test frontend health via service
    log_info "Testing frontend health via service..."
    if kubectl run --rm -i --restart=Never health-check-fe --image=curlimages/curl:latest -n "$namespace" -- \
        curl -sf http://nexvion-frontend:80/health > /dev/null 2>&1; then
        log_success "Frontend service health check passed"
    else
        log_error "Frontend service health check failed"
        all_healthy=false
    fi
    
    if [[ "$all_healthy" == "true" ]]; then
        log_success "=== All Kubernetes resources healthy ==="
        return 0
    else
        log_error "=== Some Kubernetes resources unhealthy ==="
        return 1
    fi
}

check_production() {
    local url="${1:-https://nexvion.ghanshyam.site}"
    
    log_info "=== Production Health Check ($url) ==="
    
    local all_healthy=true
    
    # Frontend health
    log_info "Checking frontend..."
    if curl -sf "$url/health" > /dev/null; then
        log_success "Frontend health check passed"
    else
        log_error "Frontend health check failed"
        all_healthy=false
    fi
    
    # Backend health
    log_info "Checking backend..."
    if curl -sf "$url/api/health" > /dev/null; then
        local health=$(curl -s "$url/api/health")
        local db_status=$(echo "$health" | jq -r '.database')
        log_success "Backend health check passed (DB: $db_status)"
    else
        log_error "Backend health check failed"
        all_healthy=false
    fi
    
    # Backend detailed health
    log_info "Checking backend detailed health..."
    if curl -sf "$url/api/health/detailed" > /dev/null; then
        local detailed=$(curl -s "$url/api/health/detailed")
        echo "$detailed" | jq .
    else
        log_warn "Detailed health endpoint not responding"
    fi
    
    # Products API
    log_info "Checking products API..."
    if curl -sf "$url/api/products" > /dev/null; then
        local products=$(curl -s "$url/api/products")
        local total=$(echo "$products" | jq -r '.total')
        log_success "Products API working (total: $total)"
    else
        log_error "Products API not responding"
        all_healthy=false
    fi
    
    # SSL Certificate
    log_info "Checking SSL certificate..."
    local host=$(echo "$url" | sed -E 's|^https?://||' | cut -d'/' -f1)
    local cert_info=$(echo | openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)
    if [[ -n "$cert_info" ]]; then
        log_success "SSL certificate valid"
        echo "$cert_info"
    else
        log_warn "Could not verify SSL certificate"
    fi
    
    if [[ "$all_healthy" == "true" ]]; then
        log_success "=== Production health checks passed ==="
        return 0
    else
        log_error "=== Production health checks failed ==="
        return 1
    fi
}

check_staging() {
    check_production "https://staging-nexvion.ghanshyam.site"
}

show_usage() {
    cat <<EOF
Usage: $0 [local|kubernetes|production|staging] [options]

Commands:
  local                    Check local Docker Compose services (default)
  kubernetes [namespace] [context]  Check Kubernetes deployment
  production [url]         Check production deployment
  staging                  Check staging deployment

Examples:
  $0 local
  $0 kubernetes nexvion
  $0 kubernetes nexvion-staging arn:aws:eks:region:account:cluster/name
  $0 production
  $0 production https://custom-domain.com
  $0 staging
EOF
}

main() {
    case "${1:-local}" in
        local)
            check_local
            ;;
        kubernetes|k8s)
            check_kubernetes "${2:-nexvion}" "${3:-}"
            ;;
        production|prod)
            check_production "${2:-https://nexvion.ghanshyam.site}"
            ;;
        staging)
            check_staging
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: $1"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"