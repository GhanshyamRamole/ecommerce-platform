bucket         = "nexvion-terraform-state"
key            = "prod/terraform.tfstate"
region         = "ap-south-1"
encrypt        = true
dynamodb_table = "terraform-locks"