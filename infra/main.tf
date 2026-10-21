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
# 1. NETWORKING (VPC, Subredes Multi-AZ, Route Tables)
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

# Subredes Públicas (Ingress / ALB)
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-${var.environment}-public-${var.availability_zones[count.index]}"
    Tier = "Public"
  }
}

# Subredes Privadas (ECS Fargate Services)
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

# Subredes de Base de Datos Aisladas (PostgreSQL)
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

# NAT Gateway para salida a internet segura desde subredes privadas
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

# Tablas de Ruteo
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
# 2. SECURITY GROUPS (Principio de Menor Privilegio)
# ==============================================================================

resource "aws_security_group" "ecs_services" {
  name        = "${var.project_name}-${var.environment}-ecs-sg"
  description = "Permite trafico entre servicios backend Go y AI Service"
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

  egress {
    description = "Salida total a internet via NAT GW"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-ecs-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "Aislamiento estricto de base de datos PostgreSQL"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Acceso PostgreSQL solo desde servicios ECS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_services.id]
  }

  egress {
    description = "Bloqueo de salida de base de datos"
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
# 3. SECRETS MANAGER (Credenciales de Base de Datos)
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
  description = "Subredes dedicadas para RDS PostgreSQL"

  tags = {
    Name = "${var.project_name}-${var.environment}-db-subnet-group"
  }
}

resource "aws_db_parameter_group" "postgres16" {
  name        = "${var.project_name}-${var.environment}-pg16-params"
  family      = "postgres16"
  description = "Parametros optimizados para alta concurrencia y pgvector"

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
  identifier                  = "${var.project_name}-${var.environment}-db"
  engine                      = "postgres"
  engine_version              = "16.2"
  instance_class              = var.db_instance_class
  allocated_storage           = var.db_allocated_storage
  max_allocated_storage       = 200
  storage_type                = "gp3"
  storage_encrypted           = true
  multi_az                    = var.environment == "prod"
  db_name                     = var.db_name
  username                    = var.db_username
  password                    = random_password.db_password.result
  db_subnet_group_name        = aws_db_subnet_group.rds.name
  vpc_security_group_ids      = [aws_security_group.rds.id]
  parameter_group_name        = aws_db_parameter_group.postgres16.name
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  backup_retention_period     = 14
  backup_window               = "03:00-04:00"
  maintenance_window          = "Sun:04:30-Sun:05:30"
  deletion_protection         = var.environment == "prod"
  skip_final_snapshot         = var.environment != "prod"
  final_snapshot_identifier   = "${var.project_name}-${var.environment}-db-final-snapshot"
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
  description = "Identificador de la VPC creada"
  value       = aws_vpc.main.id
}

output "rds_endpoint" {
  description = "Punto de enlace de conexión para PostgreSQL"
  value       = aws_db_instance.postgres.endpoint
}

output "ecr_portfolio_api_url" {
  description = "URL del registro ECR para portfolio-api (Go)"
  value       = aws_ecr_repository.portfolio_api.repository_url
}

output "ecr_ai_service_url" {
  description = "URL del registro ECR para ai-service (Python)"
  value       = aws_ecr_repository.ai_service.repository_url
}

output "ecs_cluster_name" {
  description = "Nombre del clúster de ECS Fargate"
  value       = aws_ecs_cluster.main.name
}
