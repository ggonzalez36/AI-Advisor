# ==============================================================================
# DATABASE: RDS PostgreSQL 16 in isolated subnets, credentials in Secrets Manager
# ==============================================================================

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

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${var.secret_prefix}/rds-credentials"
  # A recovery window protects against accidental deletion in prod; 0 allows fast teardown in dev.
  recovery_window_in_days = var.is_prod ? 30 : 0

  tags = {
    Name = "${var.name}-db-secret"
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

resource "aws_db_subnet_group" "rds" {
  name        = "${var.name}-db-subnet-group"
  subnet_ids  = var.subnet_ids
  description = "Dedicated subnets for RDS PostgreSQL"

  tags = {
    Name = "${var.name}-db-subnet-group"
  }
}

resource "aws_db_parameter_group" "postgres16" {
  name        = "${var.name}-pg16-params"
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
  identifier                          = "${var.name}-db"
  engine                              = "postgres"
  engine_version                      = "16" # Major version only: RDS picks the current default minor
  instance_class                      = var.instance_class
  allocated_storage                   = var.allocated_storage
  max_allocated_storage               = var.max_allocated_storage
  storage_type                        = "gp3"
  storage_encrypted                   = true
  multi_az                            = var.is_prod
  db_name                             = var.db_name
  username                            = var.db_username
  password                            = random_password.db_password.result
  db_subnet_group_name                = aws_db_subnet_group.rds.name
  vpc_security_group_ids              = [var.security_group_id]
  publicly_accessible                 = false
  parameter_group_name                = aws_db_parameter_group.postgres16.name
  iam_database_authentication_enabled = true
  auto_minor_version_upgrade          = true
  allow_major_version_upgrade         = false
  backup_retention_period             = var.backup_retention_days
  backup_window                       = "03:00-04:00"
  maintenance_window                  = "Sun:04:30-Sun:05:30"
  deletion_protection                 = var.is_prod
  skip_final_snapshot                 = !var.is_prod
  final_snapshot_identifier           = "${var.name}-db-final-snapshot"
  performance_insights_enabled        = true
  copy_tags_to_snapshot               = true

  tags = {
    Name = "${var.name}-db"
  }
}
