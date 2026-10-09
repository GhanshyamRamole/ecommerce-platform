#!/bin/bash
set -euo pipefail

# Nexvion E-Commerce Platform - Backup Script
# Backs up PostgreSQL database, Kubernetes resources, and Terraform state

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

BACKUP_DIR="${BACKUP_DIR:-$PROJECT_ROOT/backups}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_NAME="nexvion-backup-$TIMESTAMP"

mkdir -p "$BACKUP_DIR"

backup_local_postgres() {
    log_info "Backing up local PostgreSQL..."
    cd "$PROJECT_ROOT"
    
    if docker compose ps postgres --format json 2>/dev/null | jq -e 'all(.[]; .State == "running")' > /dev/null 2>&1; then
        local backup_file="$BACKUP_DIR/${BACKUP_NAME}-postgres.sql"
        docker compose exec -T postgres pg_dump -U postgres nexvion > "$backup_file"
        gzip "$backup_file"
        log_success "Local PostgreSQL backup saved to ${backup_file}.gz"
    else
        log_warn "Local PostgreSQL not running, skipping"
    fi
}

backup_local_volumes() {
    log_info "Backing up local Docker volumes..."
    cd "$PROJECT_ROOT"
    
    local volumes=("postgres_data" "opensearch_data")
    for vol in "${volumes[@]}"; do
        if docker volume inspect "nexvion_${vol}" > /dev/null 2>&1; then
            local backup_file="$BACKUP_DIR/${BACKUP_NAME}-volume-${vol}.tar.gz"
            docker run --rm -v "nexvion_${vol}:/data" -v "$BACKUP_DIR:/backup" alpine \
                tar czf "/backup/${BACKUP_NAME}-volume-${vol}.tar.gz" -C /data .
            log_success "Volume $vol backed up to ${backup_file}"
        else
            log_warn "Volume nexvion_${vol} not found, skipping"
        fi
    done
}

backup_kubernetes() {
    local namespace="${1:-nexvion}"
    local context="${2:-}"
    
    log_info "Backing up Kubernetes resources (namespace: $namespace)..."
    
    if [[ -n "$context" ]]; then
        kubectl config use-context "$context"
    fi
    
    if ! kubectl get namespace "$namespace" > /dev/null 2>&1; then
        log_warn "Namespace $namespace not found, skipping Kubernetes backup"
        return 0
    fi
    
    local backup_dir="$BACKUP_DIR/${BACKUP_NAME}-k8s"
    mkdir -p "$backup_dir"
    
    # Backup all resources in namespace
    local resources=(
        "deployments"
        "services"
        "configmaps"
        "secrets"
        "ingresses"
        "horizontalpodautoscalers"
        "networkpolicies"
        "persistentvolumeclaims"
        "serviceaccounts"
        "roles"
        "rolebindings"
    )
    
    for resource in "${resources[@]}"; do
        log_info "Backing up $resource..."
        kubectl get "$resource" -n "$namespace" -o yaml > "$backup_dir/${resource}.yaml" 2>/dev/null || true
    done
    
    # Backup custom resources if any
    kubectl get all -n "$namespace" -o yaml > "$backup_dir/all-resources.yaml" 2>/dev/null || true
    
    # Create archive
    tar czf "$BACKUP_DIR/${BACKUP_NAME}-k8s.tar.gz" -C "$BACKUP_DIR" "${BACKUP_NAME}-k8s"
    rm -rf "$backup_dir"
    
    log_success "Kubernetes backup saved to $BACKUP_DIR/${BACKUP_NAME}-k8s.tar.gz"
}

backup_terraform_state() {
    local env="${1:-prod}"
    log_info "Backing up Terraform state for environment: $env..."
    
    local bucket="nexvion-terraform-state"
    local key="${env}/terraform.tfstate"
    local backup_file="$BACKUP_DIR/${BACKUP_NAME}-terraform-${env}.tfstate"
    
    if aws s3 cp "s3://${bucket}/${key}" "$backup_file" 2>/dev/null; then
        gzip "$backup_file"
        log_success "Terraform state backed up to ${backup_file}.gz"
    else
        log_warn "Could not backup Terraform state for $env (bucket may not exist or no permissions)"
    fi
}

backup_ecr_images() {
    log_info "Backing up ECR image references..."
    
    local backup_file="$BACKUP_DIR/${BACKUP_NAME}-ecr-images.txt"
    {
        echo "# ECR Images Backup - $TIMESTAMP"
        echo "# Repository: nexvion"
        echo ""
        aws ecr list-images --repository-name nexvion-frontend --region ap-south-1 --query 'imageIds[*]' --output json 2>/dev/null | jq -r '.[] | "\(.imageTag // .imageDigest)"' | head -20
        echo ""
        aws ecr list-images --repository-name nexvion-backend --region ap-south-1 --query 'imageIds[*]' --output json 2>/dev/null | jq -r '.[] | "\(.imageTag // .imageDigest)"' | head -20
        echo ""
        aws ecr list-images --repository-name nexvion-ai-analyzer --region ap-south-1 --query 'imageIds[*]' --output json 2>/dev/null | jq -r '.[] | "\(.imageTag // .imageDigest)"' | head -20
    } > "$backup_file" 2>/dev/null || log_warn "Could not fetch ECR image list"
    
    log_success "ECR image references saved to $backup_file"
}

backup_all_local() {
    log_info "=== Starting Full Local Backup ==="
    backup_local_postgres
    backup_local_volumes
    log_success "=== Local backup complete ==="
    log_info "Backups saved to: $BACKUP_DIR"
    ls -lh "$BACKUP_DIR"/${BACKUP_NAME}*
}

backup_all_kubernetes() {
    local namespace="${1:-nexvion}"
    local context="${2:-}"
    
    log_info "=== Starting Full Kubernetes Backup ==="
    backup_kubernetes "$namespace" "$context"
    log_success "=== Kubernetes backup complete ==="
    log_info "Backups saved to: $BACKUP_DIR"
    ls -lh "$BACKUP_DIR"/${BACKUP_NAME}*
}

backup_all_production() {
    log_info "=== Starting Full Production Backup ==="
    backup_terraform_state "dev"
    backup_terraform_state "staging"
    backup_terraform_state "prod"
    backup_ecr_images
    backup_kubernetes "nexvion-dev"
    backup_kubernetes "nexvion-staging"
    backup_kubernetes "nexvion"
    log_success "=== Production backup complete ==="
    log_info "Backups saved to: $BACKUP_DIR"
    ls -lh "$BACKUP_DIR"/${BACKUP_NAME}*
}

restore_local_postgres() {
    local backup_file="${1:-}"
    
    if [[ -z "$backup_file" ]]; then
        log_error "Usage: $0 restore-local-postgres <backup-file.sql.gz>"
        exit 1
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        exit 1
    fi
    
    log_info "Restoring local PostgreSQL from $backup_file..."
    cd "$PROJECT_ROOT"
    
    if docker compose ps postgres --format json 2>/dev/null | jq -e 'all(.[]; .State == "running")' > /dev/null 2>&1; then
        gunzip -c "$backup_file" | docker compose exec -T postgres psql -U postgres -d nexvion
        log_success "Local PostgreSQL restored"
    else
        log_error "Local PostgreSQL not running"
        exit 1
    fi
}

restore_kubernetes() {
    local backup_archive="${1:-}"
    local namespace="${2:-nexvion}"
    local context="${3:-}"
    
    if [[ -z "$backup_archive" ]]; then
        log_error "Usage: $0 restore-kubernetes <backup-archive.tar.gz> [namespace] [context]"
        exit 1
    fi
    
    if [[ ! -f "$backup_archive" ]]; then
        log_error "Backup archive not found: $backup_archive"
        exit 1
    fi
    
    if [[ -n "$context" ]]; then
        kubectl config use-context "$context"
    fi
    
    log_info "Restoring Kubernetes resources from $backup_archive..."
    
    local temp_dir=$(mktemp -d)
    tar xzf "$backup_archive" -C "$temp_dir"
    
    # Find the extracted directory
    local extracted_dir=$(find "$temp_dir" -maxdepth 1 -type d -name "nexvion-backup-*" | head -1)
    
    if [[ -z "$extracted_dir" ]]; then
        log_error "Could not find extracted backup directory"
        exit 1
    fi
    
    # Apply resources in order
    local resource_order=(
        "namespaces.yaml"
        "serviceaccounts.yaml"
        "configmaps.yaml"
        "secrets.yaml"
        "persistentvolumeclaims.yaml"
        "services.yaml"
        "deployments.yaml"
        "horizontalpodautoscalers.yaml"
        "networkpolicies.yaml"
        "ingresses.yaml"
        "roles.yaml"
        "rolebindings.yaml"
    )
    
    for resource in "${resource_order[@]}"; do
        if [[ -f "$extracted_dir/$resource" ]]; then
            log_info "Restoring $resource..."
            kubectl apply -f "$extracted_dir/$resource" -n "$namespace" || true
        fi
    done
    
    # Apply any remaining resources
    for file in "$extracted_dir"/*.yaml; do
        if [[ -f "$file" ]]; then
            local basename=$(basename "$file")
            if [[ ! " ${resource_order[@]} " =~ " ${basename} " ]]; then
                log_info "Restoring $basename..."
                kubectl apply -f "$file" -n "$namespace" || true
            fi
        fi
    done
    
    rm -rf "$temp_dir"
    log_success "Kubernetes resources restored"
}

cleanup_old_backups() {
    local keep_days="${1:-30}"
    
    log_info "Cleaning up backups older than $keep_days days..."
    find "$BACKUP_DIR" -name "nexvion-backup-*" -type f -mtime +$keep_days -delete
    log_success "Old backups cleaned up"
}

list_backups() {
    log_info "Available backups in $BACKUP_DIR:"
    ls -lh "$BACKUP_DIR"/nexvion-backup-* 2>/dev/null | awk '{print $9 "  " $5 "  " $6 " " $7 " " $8}' || log_warn "No backups found"
}

show_usage() {
    cat <<EOF
Usage: $0 [command] [options]

Commands:
  backup-local                    Backup local Docker Compose (PostgreSQL + volumes)
  backup-k8s [namespace] [context]  Backup Kubernetes resources
  backup-prod                     Backup production (Terraform state, ECR, K8s)
  backup-all                      Backup everything (local + K8s + prod)
  
  restore-local-postgres <file>   Restore local PostgreSQL from backup
  restore-k8s <archive> [ns] [ctx] Restore Kubernetes from backup
  
  cleanup [days]                  Remove backups older than N days (default: 30)
  list                            List all available backups

Examples:
  $0 backup-local
  $0 backup-k8s nexvion
  $0 backup-k8s nexvion-staging arn:aws:eks:region:account:cluster/name
  $0 backup-prod
  $0 restore-local-postgres backups/nexvion-backup-20240115_120000-postgres.sql.gz
  $0 restore-k8s backups/nexvion-backup-20240115_120000-k8s.tar.gz nexvion
  $0 cleanup 7
  $0 list
EOF
}

main() {
    case "${1:-}" in
        backup-local)
            backup_all_local
            ;;
        backup-k8s)
            backup_all_kubernetes "${2:-nexvion}" "${3:-}"
            ;;
        backup-prod)
            backup_all_production
            ;;
        backup-all)
            backup_all_local
            backup_all_kubernetes "nexvion"
            backup_all_production
            ;;
        restore-local-postgres)
            restore_local_postgres "${2:-}"
            ;;
        restore-k8s)
            restore_kubernetes "${2:-}" "${3:-nexvion}" "${4:-}"
            ;;
        cleanup)
            cleanup_old_backups "${2:-30}"
            ;;
        list)
            list_backups
            ;;
        help|--help|-h|"")
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