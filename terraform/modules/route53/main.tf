variable "zone_name" {
  description = "Route53 hosted zone name (e.g., ghanshyam.site)"
  type        = string
}

variable "record_name" {
  description = "Record name (e.g., nexvion)"
  type        = string
  default     = "nexvion"
}

variable "alb_dns_name" {
  description = "ALB DNS name"
  type        = string
}

variable "alb_zone_id" {
  description = "ALB zone ID"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}

data "aws_route53_zone" "main" {
  name         = var.zone_name
  private_zone = false
}

resource "aws_route53_record" "main" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${var.record_name}.${var.zone_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }

  ttl = 60
}

output "record_fqdn" {
  value = aws_route53_record.main.fqdn
}