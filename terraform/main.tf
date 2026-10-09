terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket         = "nexvion-terraform-state"
    region         = "ap-south-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
    # key must be provided via -backend-config during init (e.g., -backend-config="key=dev/terraform.tfstate")
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "domain_name" {
  description = "Domain name for Route53"
  type        = string
  default     = "ghanshyam.site"
}

variable "subdomain" {
  description = "Subdomain for the application"
  type        = string
  default     = "nexvion"
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS"
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "EC2 key pair name for PostgreSQL instance"
  type        = string
}

variable "db_password" {
  description = "PostgreSQL password"
  type        = string
  sensitive   = true
}

variable "vpc_cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for database subnets"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "ec2_instance_type" {
  description = "EC2 instance type for PostgreSQL"
  type        = string
  default     = "t3.micro"
}

variable "use_rds" {
  description = "Use RDS instead of EC2 for PostgreSQL"
  type        = bool
  default     = false
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "rds_allocated_storage" {
  description = "RDS allocated storage in GB"
  type        = number
  default     = 20
}

variable "rds_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16.3"
}

variable "rds_backup_retention_period" {
  description = "RDS backup retention period in days"
  type        = number
  default     = 7
}

variable "rds_skip_final_snapshot" {
  description = "Skip final snapshot on RDS deletion"
  type        = bool
  default     = false
}

variable "rds_deletion_protection" {
  description = "Enable RDS deletion protection"
  type        = bool
  default     = true
}

variable "ec2_volume_size" {
  description = "EC2 root volume size in GB"
  type        = number
  default     = 20
}

variable "eks_node_instance_types" {
  description = "EKS node instance types"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_desired_size" {
  description = "EKS node desired size"
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "EKS node min size"
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "EKS node max size"
  type        = number
  default     = 5
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project     = "nexvion"
    Environment = ""
    ManagedBy   = "terraform"
  }
}

locals {
  name_prefix = "nexvion-${var.environment}"
  common_tags = merge(var.tags, { Environment = var.environment })
}

module "vpc" {
  source = "./modules/vpc"

  cidr_block            = var.vpc_cidr_block
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs
  tags                  = local.common_tags
}

module "ec2_postgres" {
  count = var.use_rds ? 0 : 1
  source = "./modules/ec2-postgres"

  instance_type     = var.ec2_instance_type
  key_name          = var.key_pair_name
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.database_subnet_ids
  security_group_ids = [module.eks.node_security_group_id]
  db_name           = "nexvion"
  db_user           = "postgres"
  db_password       = var.db_password
  volume_size       = var.ec2_volume_size
  vpc_cidr          = var.vpc_cidr_block

  tags = local.common_tags

  depends_on = [module.eks]
}

module "rds_postgres" {
  count = var.use_rds ? 1 : 0
  source = "./modules/rds-postgres"

  db_name                = "nexvion"
  db_username            = "postgres"
  db_password            = var.db_password
  instance_class         = var.rds_instance_class
  allocated_storage      = var.rds_allocated_storage
  engine_version         = var.rds_engine_version
  vpc_id                 = module.vpc.vpc_id
  subnet_ids             = module.vpc.database_subnet_ids
  security_group_ids     = [module.eks.node_security_group_id]
  backup_retention_period = var.rds_backup_retention_period
  skip_final_snapshot    = var.rds_skip_final_snapshot
  deletion_protection    = var.rds_deletion_protection

  tags = local.common_tags

  depends_on = [module.eks]
}

module "eks" {
  source = "./modules/eks"

  cluster_name        = "${local.name_prefix}-cluster"
  vpc_id              = module.vpc.vpc_id
  vpc_cidr_block      = var.vpc_cidr_block
  subnet_ids          = module.vpc.private_subnet_ids
  node_instance_types = var.eks_node_instance_types
  node_desired_size   = var.eks_node_desired_size
  node_min_size       = var.eks_node_min_size
  node_max_size       = var.eks_node_max_size
  environment         = var.environment
  public_access_cidrs = [var.vpc_cidr_block]

  tags = local.common_tags
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Security group for ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb" })
}

module "alb" {
  source = "./modules/alb"

  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.public_subnet_ids
  security_group_ids = [aws_security_group.alb.id]
  certificate_arn    = var.certificate_arn

  tags = local.common_tags
}

module "route53" {
  source       = "./modules/route53"
  zone_name    = var.domain_name
  record_name  = var.subdomain
  alb_dns_name = module.alb.alb_dns_name
  alb_zone_id  = module.alb.alb_zone_id

  tags = local.common_tags
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "postgres_endpoint" {
  value     = var.use_rds ? module.rds_postgres[0].endpoint : module.ec2_postgres[0].private_ip
  sensitive = true
}

output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "app_url" {
  value = "https://${module.route53.record_fqdn}"
}