# Terraform Environments

This directory contains environment-specific configurations for the Nexvion E-Commerce Platform infrastructure.

## Structure

```
terraform/environments/
├── dev/
│   └── terraform.tfvars       # Development environment
├── staging/
│   └── terraform.tfvars       # Staging environment
└── prod/
    └── terraform.tfvars       # Production environment
```

## Usage

### Deploy to Development

```bash
cd terraform
terraform init
terraform plan -var-file="environments/dev/terraform.tfvars"
terraform apply -var-file="environments/dev/terraform.tfvars"
```

### Deploy to Staging

```bash
cd terraform
terraform init
terraform plan -var-file="environments/staging/terraform.tfvars"
terraform apply -var-file="environments/staging/terraform.tfvars"
```

### Deploy to Production

```bash
cd terraform
terraform init
terraform plan -var-file="environments/prod/terraform.tfvars"
terraform apply -var-file="environments/prod/terraform.tfvars"
```

## State Management

Each environment uses a separate state file in the S3 bucket:

- **Dev**: `s3://nexvion-terraform-state/dev/terraform.tfstate`
- **Staging**: `s3://nexvion-terraform-state/staging/terraform.tfstate`
- **Prod**: `s3://nexvion-terraform-state/prod/terraform.tfstate`

### Backend Configuration

To use separate state files, update the backend configuration in `terraform/main.tf` or use a wrapper script:

```bash
# For dev
terraform init -backend-config="key=dev/terraform.tfstate"

# For staging
terraform init -backend-config="key=staging/terraform.tfstate"

# For prod
terraform init -backend-config="key=prod/terraform.tfstate"
```

## Environment Differences

| Setting | Dev | Staging | Prod |
|---------|-----|---------|------|
| VPC CIDR | 10.1.0.0/16 | 10.2.0.0/16 | 10.0.0.0/16 |
| EKS Node Type | t3.small | t3.medium | t3.medium |
| EKS Desired Nodes | 1 | 2 | 3 |
| EKS Max Nodes | 2 | 3 | 10 |
| PostgreSQL Instance | t3.micro | t3.small | t3.medium |
| PostgreSQL Volume | 20 GB | 50 GB | 100 GB |
| NAT Gateway | Single (cost) | Single (cost) | Per AZ (HA) |
| Deletion Protection | Disabled | Enabled | Enabled |

## Required Secrets

Before deploying, ensure these are configured:

1. **AWS Credentials**: `aws configure` or environment variables
2. **Key Pair**: Create EC2 key pair in each region
3. **ACM Certificate**: Request certificate for `*.ghanshyam.site` in `ap-south-1`
4. **Database Password**: Set strong password in tfvars
5. **Domain**: Ensure `ghanshyam.site` is hosted in Route53

## CI/CD Integration

The GitHub Actions workflow automatically deploys:
- `develop` branch → Staging environment
- `main` branch → Production environment (with manual approval)

Required GitHub Secrets:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `DB_PASSWORD`
- `JWT_SECRET_KEY`