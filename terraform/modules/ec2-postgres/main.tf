variable "instance_type" {
  description = "EC2 instance type for PostgreSQL"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "Database subnet IDs"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs to attach"
  type        = list(string)
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "nexvion"
}

variable "db_user" {
  description = "Database user"
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "Database password"
  type        = string
}

variable "volume_size" {
  description = "Root volume size in GB"
  type        = number
  default     = 20
}

variable "vpc_cidr" {
  description = "VPC CIDR block for pg_hba.conf"
  type        = string
}

variable "bastion_sg_id" {
  description = "Security group ID for bastion host (for SSH access)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_security_group" "postgres" {
  name        = "nexvion-postgres-sg"
  description = "Security group for PostgreSQL EC2"
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL from EKS nodes"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    security_groups = var.security_group_ids
  }

  ingress {
    description = "SSH from bastion host only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    security_groups = var.bastion_sg_id != "" ? [var.bastion_sg_id] : []
    cidr_blocks = []
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "nexvion-postgres-sg" })
}

resource "aws_instance" "postgres" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.postgres.id] + var.security_group_ids

  root_block_device {
    volume_type = "gp3"
    volume_size = var.volume_size
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    db_name     = var.db_name
    db_user     = var.db_user
    db_password = var.db_password
    vpc_cidr    = var.vpc_cidr
  })

  tags = merge(var.tags, { Name = "nexvion-postgres" })
}

output "instance_id" {
  value = aws_instance.postgres.id
}

output "private_ip" {
  value = aws_instance.postgres.private_ip
}

output "public_ip" {
  value = aws_instance.postgres.public_ip
}

output "security_group_id" {
  value = aws_security_group.postgres.id
}