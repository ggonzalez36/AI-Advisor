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
    tags = var.tags
  }
}

# ==============================================================================
# 1. NETWORKING (VPC, Multi-AZ Subnets, Route Tables)
# ==============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-${var.environment}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-igw"
  }
}

# Public Subnets (Ingress / ALB)
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false # The ALB and NAT use explicit IPs; nothing gets a public IP by default

  tags = {
    Name = "${var.project_name}-${var.environment}-public-${var.availability_zones[count.index]}"
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
    Name = "${var.project_name}-${var.environment}-private-${var.availability_zones[count.index]}"
    Tier = "Private"
  }
}

# Isolated Database Subnets (PostgreSQL)
resource "aws_subnet" "database" {
  count             = length(var.database_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.database_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.project_name}-${var.environment}-db-${var.availability_zones[count.index]}"
    Tier = "Database"
  }
}

# NAT Gateway for secure internet egress from private subnets
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-gw"
  }

  depends_on = [aws_internet_gateway.igw]
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-rt-public"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-rt-private"
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
  route_table_id = aws_route_table.private.id
}

# ==============================================================================
# 2. SECURITY GROUPS (Principle of Least Privilege)
# ==============================================================================

resource "aws_security_group" "ecs_services" {
  name        = "${var.project_name}-${var.environment}-ecs-sg"
  description = "Allows traffic between the Go backend and AI Service"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP Go Backend API"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "HTTP AI Service Python"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Least privilege: PostgreSQL only to the database subnets
  egress {
    description = "PostgreSQL to database subnets"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.database_subnet_cidrs
  }

  # Accepted (documented) risk: the AI Service calls the external LLM API and AWS APIs
  # over HTTPS through the NAT. Restricted to TCP 443. Future mitigation: VPC endpoints for AWS
  # and an egress proxy with a domain allowlist for the LLM provider.
  #trivy:ignore:AVD-AWS-0104
  egress {
    description = "Outbound HTTPS via NAT (LLM API and AWS services)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-ecs-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "Strict isolation for the PostgreSQL database"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL access from ECS services only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_services.id]
  }

  egress {
    description = "Database egress lockdown"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-rds-sg"
  }
}

# ==============================================================================
# 3. SECRETS MANAGER (Database Credentials)
# ==============================================================================

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.project_name}/${var.environment}/rds-credentials"
  recovery_window_in_days = 0

  tags = {
    Name = "${var.project_name}-${var.environment}-db-secret"
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

# ==============================================================================
# 4. RDS POSTGRESQL (PostgreSQL 16, pgvector, Multi-AZ)
# ==============================================================================

resource "aws_db_subnet_group" "rds" {
  name        = "${var.project_name}-${var.environment}-db-subnet-group"
  subnet_ids  = aws_subnet.database[*].id
  description = "Dedicated subnets for RDS PostgreSQL"

  tags = {
    Name = "${var.project_name}-${var.environment}-db-subnet-group"
  }
}

resource "aws_db_parameter_group" "postgres16" {
  name        = "${var.project_name}-${var.environment}-pg16-params"
  family      = "postgres16"
  description = "Parameters tuned for high concurrency and pgvector"

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements,pgcrypto"
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
  identifier                   = "${var.project_name}-${var.environment}-db"
  engine                       = "postgres"
  engine_version               = "16.2"
  instance_class               = var.db_instance_class
  allocated_storage            = var.db_allocated_storage
  max_allocated_storage        = 200
  storage_type                 = "gp3"
  storage_encrypted            = true
  multi_az                     = var.environment == "prod"
  db_name                      = var.db_name
  username                     = var.db_username
  password                     = random_password.db_password.result
  db_subnet_group_name         = aws_db_subnet_group.rds.name
  vpc_security_group_ids       = [aws_security_group.rds.id]
  parameter_group_name         = aws_db_parameter_group.postgres16.name
  auto_minor_version_upgrade   = true
  allow_major_version_upgrade  = false
  backup_retention_period      = 14
  backup_window                = "03:00-04:00"
  maintenance_window           = "Sun:04:30-Sun:05:30"
  deletion_protection          = var.environment == "prod"
  skip_final_snapshot          = var.environment != "prod"
  final_snapshot_identifier    = "${var.project_name}-${var.environment}-db-final-snapshot"
  performance_insights_enabled = true

  tags = {
    Name = "${var.project_name}-${var.environment}-db"
  }
}

# ==============================================================================
# 5. ECR REPOSITORIES (DevSecOps: Image Scanning on Push)
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

# ==============================================================================
# 6. ECS CLUSTER & LOGGING (Fargate)
# ==============================================================================

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-ecs-cluster"
  }
}

resource "aws_cloudwatch_log_group" "portfolio_api" {
  name              = "/ecs/${var.project_name}-${var.environment}/portfolio-api"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-api-logs"
  }
}

resource "aws_cloudwatch_log_group" "ai_service" {
  name              = "/ecs/${var.project_name}-${var.environment}/ai-service"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-ai-logs"
  }
}

# ==============================================================================
# 7. OUTPUTS
# ==============================================================================

output "vpc_id" {
  description = "ID of the created VPC"
  value       = aws_vpc.main.id
}

output "rds_endpoint" {
  description = "PostgreSQL connection endpoint"
  value       = aws_db_instance.postgres.endpoint
}

output "ecr_portfolio_api_url" {
  description = "ECR registry URL for portfolio-api (Go)"
  value       = aws_ecr_repository.portfolio_api.repository_url
}

output "ecr_ai_service_url" {
  description = "ECR registry URL for ai-service (Python)"
  value       = aws_ecr_repository.ai_service.repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS Fargate cluster"
  value       = aws_ecs_cluster.main.name
}
