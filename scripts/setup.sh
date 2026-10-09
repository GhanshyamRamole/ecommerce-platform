#!/bin/bash
set -euo pipefail

# Nexvion E-Commerce Platform - Setup Script
# Installs all prerequisites for local development and deployment

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

check_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
        OS="windows"
    else
        log_error "Unsupported OS: $OSTYPE"
        exit 1
    fi
    log_info "Detected OS: $OS"
}

install_docker_linux() {
    log_info "Installing Docker..."
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg lsb-release
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo usermod -aG docker "$USER"
    log_success "Docker installed. Please log out and back in for group changes."
}

install_docker_macos() {
    log_info "Please install Docker Desktop from https://www.docker.com/products/docker-desktop/"
    log_warn "Skipping automated Docker install on macOS"
}

install_kubectl() {
    log_info "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${OS}/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    log_success "kubectl installed"
}

install_helm() {
    log_info "Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_success "Helm installed"
}

install_terraform() {
    log_info "Installing Terraform..."
    TERRAFORM_VERSION="1.8.0"
    curl -LO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${OS}_amd64.zip"
    unzip -o "terraform_${TERRAFORM_VERSION}_${OS}_amd64.zip"
    sudo mv terraform /usr/local/bin/
    rm "terraform_${TERRAFORM_VERSION}_${OS}_amd64.zip"
    log_success "Terraform installed"
}

install_aws_cli() {
    log_info "Installing AWS CLI v2..."
    if [[ "$OS" == "linux" ]]; then
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -o awscliv2.zip
        sudo ./aws/install
        rm -rf aws awscliv2.zip
    elif [[ "$OS" == "macos" ]]; then
        curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
        sudo installer -pkg AWSCLIV2.pkg -target /
        rm AWSCLIV2.pkg
    fi
    log_success "AWS CLI installed"
}

install_python_tools() {
    log_info "Installing Python development tools..."
    if [[ "$OS" == "linux" ]]; then
        sudo apt-get install -y python3 python3-venv python3-pip
    elif [[ "$OS" == "macos" ]]; then
        brew install python@3.11
    fi
    python3 -m pip install --user --upgrade pip
    python3 -m pip install --user ruff mypy pytest pytest-asyncio pytest-cov
    log_success "Python tools installed"
}

setup_project() {
    log_info "Setting up project..."
    cd "$PROJECT_ROOT"
    
    if [[ ! -f ".env" ]]; then
        log_info "Creating .env file from template..."
        cat > .env <<EOF
# Database
DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/nexvion
DB_PASSWORD=postgres

# JWT
JWT_SECRET_KEY=dev-secret-key-change-in-production-min-32-chars

# CORS
CORS_ORIGINS=["http://localhost:8080","http://localhost:3000"]

# Debug
DEBUG=true

# OpenSearch (for AI analyzer)
OPENSEARCH_HOST=localhost
OPENSEARCH_PORT=9200
OPENSEARCH_USER=admin
OPENSEARCH_PASSWORD=admin
OPENSEARCH_SSL=false
OPENSEARCH_VERIFY=false
OPENSEARCH_INDEX=logs-*

# OpenAI (for AI analyzer)
OPENAI_API_KEY=your-openai-api-key
OPENAI_MODEL=gpt-4
EOF
        log_warn "Created .env file. Please update with your values."
    fi

    if [[ ! -f "terraform/environments/dev/terraform.tfvars" ]]; then
        log_info "Creating terraform.tfvars templates for all environments..."
        
        # Dev environment
        cat > terraform/environments/dev/terraform.tfvars <<EOF
aws_region       = "ap-south-1"
environment      = "dev"
domain_name      = "ghanshyam.site"
subdomain        = "nexvion-dev"
key_pair_name    = "dev-key-pair"
db_password      = "dev-password-change-me"
certificate_arn  = ""

vpc_cidr_block           = "10.1.0.0/16"
public_subnet_cidrs      = ["10.1.1.0/24", "10.1.2.0/24"]
private_subnet_cidrs     = ["10.1.11.0/24", "10.1.12.0/24"]
database_subnet_cidrs    = ["10.1.21.0/24", "10.1.22.0/24"]

eks_node_instance_types  = ["t3.small"]
eks_node_desired_size    = 1
eks_node_min_size        = 1
eks_node_max_size        = 2

ec2_instance_type        = "t3.micro"
ec2_volume_size          = 20

tags = {
  Project     = "nexvion"
  Environment = "dev"
  ManagedBy   = "terraform"
  Owner       = "dev-team"
}
EOF

        # Staging environment
        cat > terraform/environments/staging/terraform.tfvars <<EOF
aws_region       = "ap-south-1"
environment      = "staging"
domain_name      = "ghanshyam.site"
subdomain        = "staging-nexvion"
key_pair_name    = "staging-key-pair"
db_password      = "staging-password-change-me"
certificate_arn  = ""

vpc_cidr_block           = "10.2.0.0/16"
public_subnet_cidrs      = ["10.2.1.0/24", "10.2.2.0/24"]
private_subnet_cidrs     = ["10.2.11.0/24", "10.2.12.0/24"]
database_subnet_cidrs    = ["10.2.21.0/24", "10.2.22.0/24"]

eks_node_instance_types  = ["t3.medium"]
eks_node_desired_size    = 2
eks_node_min_size        = 1
eks_node_max_size        = 3

ec2_instance_type        = "t3.small"
ec2_volume_size          = 50

tags = {
  Project     = "nexvion"
  Environment = "staging"
  ManagedBy   = "terraform"
  Owner       = "devops-team"
}
EOF

        # Production environment
        cat > terraform/environments/prod/terraform.tfvars <<EOF
aws_region       = "ap-south-1"
environment      = "prod"
domain_name      = "ghanshyam.site"
subdomain        = "nexvion"
key_pair_name    = "prod-key-pair"
db_password      = "prod-super-secure-password-change-me"
certificate_arn  = ""

vpc_cidr_block           = "10.0.0.0/16"
public_subnet_cidrs      = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs     = ["10.0.11.0/24", "10.0.12.0/24"]
database_subnet_cidrs    = ["10.0.21.0/24", "10.0.22.0/24"]

eks_node_instance_types  = ["t3.medium"]
eks_node_desired_size    = 3
eks_node_min_size        = 2
eks_node_max_size        = 10

ec2_instance_type        = "t3.medium"
ec2_volume_size          = 100

tags = {
  Project     = "nexvion"
  Environment = "prod"
  ManagedBy   = "terraform"
  Owner       = "platform-team"
  Compliance  = "required"
  Backup      = "daily"
}
EOF

        log_warn "Created terraform/environments/*/terraform.tfvars. Please update with your values."
    fi

    log_success "Project setup complete"
}

verify_installation() {
    log_info "Verifying installation..."
    local missing=()
    
    for cmd in docker docker-compose kubectl helm terraform aws python3; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        else
            log_success "$cmd: $($cmd version 2>/dev/null | head -1)"
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing commands: ${missing[*]}"
        return 1
    fi
    
    log_success "All tools installed successfully!"
}

main() {
    log_info "=== Nexvion E-Commerce Platform Setup ==="
    
    check_os
    
    case "${1:-all}" in
        docker)
            if [[ "$OS" == "linux" ]]; then install_docker_linux; else install_docker_macos; fi
            ;;
        kubectl)
            install_kubectl
            ;;
        helm)
            install_helm
            ;;
        terraform)
            install_terraform
            ;;
        aws)
            install_aws_cli
            ;;
        python)
            install_python_tools
            ;;
        project)
            setup_project
            ;;
        verify)
            verify_installation
            ;;
        all)
            if [[ "$OS" == "linux" ]]; then install_docker_linux; else install_docker_macos; fi
            install_kubectl
            install_helm
            install_terraform
            install_aws_cli
            install_python_tools
            setup_project
            verify_installation
            ;;
        *)
            echo "Usage: $0 [docker|kubectl|helm|terraform|aws|python|project|verify|all]"
            exit 1
            ;;
    esac
    
    log_success "Setup completed!"
    log_info "Next steps:"
    log_info "  1. Log out and back in (for Docker group)"
    log_info "  2. Configure AWS: aws configure"
    log_info "  3. Update .env and terraform/terraform.tfvars"
    log_info "  4. Run: ./scripts/deploy.sh local"
}

main "$@"