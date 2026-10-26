# ==============================================================================
# SECURITY GROUPS (least privilege, chained ALB -> ECS -> RDS)
# Rules are separate resources so the groups can reference each other without cycles.
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

locals {
  service_ports = toset([for p in var.service_ports : tostring(p)])
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "Public entry point: HTTP and HTTPS from the internet"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-alb-sg"
  }
}

resource "aws_security_group" "ecs_services" {
  name        = "${var.name}-ecs-sg"
  description = "Fargate tasks: reachable only from the ALB and from each other"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-ecs-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-sg"
  description = "Strict isolation for the PostgreSQL database"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-rds-sg"
  }
}

# --- ALB ---
# Only when the ALB is internet-facing (no API Gateway in front). Accepted (documented) risk:
# a public load balancer must accept traffic from the internet; it only exposes 80/443.
#trivy:ignore:AVD-AWS-0107
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count             = var.allow_public_alb_ingress ? 1 : 0
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

#trivy:ignore:AVD-AWS-0107
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  count             = var.allow_public_alb_ingress ? 1 : 0
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet (redirected to HTTPS when a certificate is set)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_services" {
  for_each = local.service_ports

  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to ECS services on port ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  referenced_security_group_id = aws_security_group.ecs_services.id
}

# --- ECS services ---
resource "aws_vpc_security_group_ingress_rule" "services_from_alb" {
  for_each = local.service_ports

  security_group_id            = aws_security_group.ecs_services.id
  description                  = "Traffic from the ALB on port ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "services_internal" {
  security_group_id            = aws_security_group.ecs_services.id
  description                  = "ai-service calls portfolio-api via Cloud Map"
  ip_protocol                  = "tcp"
  from_port                    = var.internal_port
  to_port                      = var.internal_port
  referenced_security_group_id = aws_security_group.ecs_services.id
}

resource "aws_vpc_security_group_egress_rule" "services_internal" {
  security_group_id            = aws_security_group.ecs_services.id
  description                  = "ai-service to portfolio-api"
  ip_protocol                  = "tcp"
  from_port                    = var.internal_port
  to_port                      = var.internal_port
  referenced_security_group_id = aws_security_group.ecs_services.id
}

resource "aws_vpc_security_group_egress_rule" "services_to_db" {
  security_group_id            = aws_security_group.ecs_services.id
  description                  = "PostgreSQL to the database security group"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.rds.id
}

# Accepted (documented) risk: the AI Service calls the external LLM API, and tasks pull images
# and read secrets from AWS APIs, over HTTPS through the NAT. Restricted to TCP 443.
# Future mitigation: VPC endpoints for AWS services and an egress proxy with a domain
# allowlist for the LLM provider.
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "services_https" {
  security_group_id = aws_security_group.ecs_services.id
  description       = "Outbound HTTPS via NAT (LLM API, ECR, Secrets Manager, CloudWatch)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# --- RDS ---
resource "aws_vpc_security_group_ingress_rule" "db_from_services" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL access from ECS services only"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.ecs_services.id
}
