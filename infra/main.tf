terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, { Environment = var.environment })
  }
}

locals {
  name    = "${var.project_name}-${var.environment}"
  is_prod = var.environment == "prod"
  # One NAT gateway per AZ removes the single point of failure for outbound traffic;
  # a single NAT keeps dev/staging cheaper. The trade-off is explicit and configurable.
  single_nat = coalesce(var.single_nat_gateway, !local.is_prod)
  nat_count  = local.single_nat ? 1 : length(var.availability_zones)
}

# ==============================================================================
# 1. NETWORKING (VPC, Multi-AZ Subnets, NAT, Route Tables)
# ==============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name}-igw"
  }
}

# Public Subnets (ALB, NAT)
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false # The ALB and NAT use explicit IPs; nothing gets a public IP by default

  tags = {
    Name = "${local.name}-public-${var.availability_zones[count.index]}"
    Tier = "Public"
  }
}

# Private Subnets (ECS Fargate Services)
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${local.name}-private-${var.availability_zones[count.index]}"
    Tier = "Private"
  }
}

# Isolated Database Subnets (PostgreSQL), no route to the internet
resource "aws_subnet" "database" {
  count             = length(var.database_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.database_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${local.name}-db-${var.availability_zones[count.index]}"
    Tier = "Database"
  }
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = {
    Name = "${local.name}-nat-eip-${count.index}"
  }
}

resource "aws_nat_gateway" "nat" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${local.name}-nat-gw-${count.index}"
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${local.name}-rt-public"
  }
}

# One private route table per AZ, each pointing at the NAT in its own AZ (or the single NAT)
resource "aws_route_table" "private" {
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[local.single_nat ? 0 : count.index].id
  }

  tags = {
    Name = "${local.name}-rt-private-${count.index}"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ==============================================================================
# 2. SECURITY GROUPS (least privilege, chained ALB -> ECS -> RDS)
# Rules are separate resources so the groups can reference each other without cycles.
# ==============================================================================

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Public entry point: HTTP and HTTPS from the internet"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name}-alb-sg"
  }
}

resource "aws_security_group" "ecs_services" {
  name        = "${local.name}-ecs-sg"
  description = "Fargate tasks: reachable only from the ALB and from each other"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name}-ecs-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "Strict isolation for the PostgreSQL database"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name}-rds-sg"
  }
}

# --- ALB ---
# Accepted (documented) risk: a public load balancer must accept traffic from the internet.
# It only exposes 80/443; HTTP redirects to HTTPS when a certificate is configured.
#trivy:ignore:AVD-AWS-0107
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

#trivy:ignore:AVD-AWS-0107
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet (redirected to HTTPS when a certificate is set)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_services" {
  for_each = toset(["8080", "8000"])

  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to ECS services on port ${each.value}"
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  referenced_security_group_id = aws_security_group.ecs_services.id
}

# --- ECS services ---
resource "aws_vpc_security_group_ingress_rule" "services_from_alb" {
  for_each = toset(["8080", "8000"])

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
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.ecs_services.id
}

resource "aws_vpc_security_group_egress_rule" "services_internal" {
  security_group_id            = aws_security_group.ecs_services.id
  description                  = "ai-service to portfolio-api"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
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

# ==============================================================================
# 3. SECRETS MANAGER
# ==============================================================================

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${var.project_name}/${var.environment}/rds-credentials"
  # A recovery window protects against accidental deletion in prod; 0 allows fast teardown in dev.
  recovery_window_in_days = local.is_prod ? 30 : 0

  tags = {
    Name = "${local.name}-db-secret"
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials_val" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.postgres.address
    port     = 5432
    username = var.db_username
    password = random_password.db_password.result
    database = var.db_name
  })
}

# Runtime configuration for the AI service. The value is set out-of-band (never in code or
# state), e.g. `aws secretsmanager put-secret-value`, as JSON with REVIEWER_TOKENS and,
# when llm_provider = "anthropic", ANTHROPIC_API_KEY.
resource "aws_secretsmanager_secret" "ai_service" {
  name                    = "${var.project_name}/${var.environment}/ai-service"
  recovery_window_in_days = local.is_prod ? 30 : 0

  tags = {
    Name = "${local.name}-ai-service-secret"
  }
}

# ==============================================================================
# 4. RDS POSTGRESQL (PostgreSQL 16, Multi-AZ in prod)
# ==============================================================================

resource "aws_db_subnet_group" "rds" {
  name        = "${local.name}-db-subnet-group"
  subnet_ids  = aws_subnet.database[*].id
  description = "Dedicated subnets for RDS PostgreSQL"

  tags = {
    Name = "${local.name}-db-subnet-group"
  }
}

resource "aws_db_parameter_group" "postgres16" {
  name        = "${local.name}-pg16-params"
  family      = "postgres16"
  description = "Query statistics and connection logging"

  # pgcrypto and pgvector are not preload libraries: enable them with CREATE EXTENSION.
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }
}

resource "aws_db_instance" "postgres" {
  identifier                          = "${local.name}-db"
  engine                              = "postgres"
  engine_version                      = "16" # Major version only: RDS picks the current default minor
  instance_class                      = var.db_instance_class
  allocated_storage                   = var.db_allocated_storage
  max_allocated_storage               = 200
  storage_type                        = "gp3"
  storage_encrypted                   = true
  multi_az                            = local.is_prod
  db_name                             = var.db_name
  username                            = var.db_username
  password                            = random_password.db_password.result
  db_subnet_group_name                = aws_db_subnet_group.rds.name
  vpc_security_group_ids              = [aws_security_group.rds.id]
  parameter_group_name                = aws_db_parameter_group.postgres16.name
  iam_database_authentication_enabled = true
  auto_minor_version_upgrade          = true
  allow_major_version_upgrade         = false
  backup_retention_period             = 14
  backup_window                       = "03:00-04:00"
  maintenance_window                  = "Sun:04:30-Sun:05:30"
  deletion_protection                 = local.is_prod
  skip_final_snapshot                 = !local.is_prod
  final_snapshot_identifier           = "${local.name}-db-final-snapshot"
  performance_insights_enabled        = true
  copy_tags_to_snapshot               = true

  tags = {
    Name = "${local.name}-db"
  }
}

# ==============================================================================
# 5. ECR REPOSITORIES (immutable tags, scan on push, lifecycle)
# ==============================================================================

resource "aws_ecr_repository" "portfolio_api" {
  name                 = "${var.project_name}/portfolio-api"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.project_name}-portfolio-api-repo"
  }
}

resource "aws_ecr_repository" "ai_service" {
  name                 = "${var.project_name}/ai-service"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.project_name}-ai-service-repo"
  }
}

# Keep the last 30 images per repository to bound storage cost
resource "aws_ecr_lifecycle_policy" "keep_recent" {
  for_each = {
    portfolio_api = aws_ecr_repository.portfolio_api.name
    ai_service    = aws_ecr_repository.ai_service.name
  }

  repository = each.value
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire images beyond the 30 most recent"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}
