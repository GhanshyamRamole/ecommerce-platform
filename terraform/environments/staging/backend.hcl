bucket         = "nexvion-terraform-state"
key            = "staging/terraform.tfstate"
region         = "ap-south-1"
encrypt        = true
dynamodb_table = "terraform-locks"