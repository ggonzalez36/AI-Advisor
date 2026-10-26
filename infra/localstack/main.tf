# ==============================================================================
# LOCALSTACK ENVIRONMENT
# Applies the same modules as the AWS root against LocalStack, so they are created for real
# (API calls, dependencies, teardown) without an AWS account. LocalStack's free edition
# emulates EC2/VPC, IAM, S3, DynamoDB, KMS, Secrets Manager, CloudWatch, SQS and SNS; ECS,
# ALB, RDS, ECR, API Gateway v2 and Cognito need LocalStack Pro, so those modules are covered
# by `terraform test` mocks.
#
#   docker compose -f localstack/docker-compose.yml up -d
#   terraform -chdir=localstack init && terraform -chdir=localstack apply -auto-approve
#   ./localstack/smoke-test.sh
# ==============================================================================

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

# Dummy credentials: LocalStack accepts any. Never point this provider at real AWS.
provider "aws" {
  region     = var.aws_region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    cloudwatch     = var.endpoint
    dynamodb       = var.endpoint
    ec2            = var.endpoint
    iam            = var.endpoint
    kms            = var.endpoint
    logs           = var.endpoint
    s3             = var.endpoint
    secretsmanager = var.endpoint
    sns            = var.endpoint
    sqs            = var.endpoint
    sts            = var.endpoint
  }

  default_tags {
    tags = {
      Project     = "fin-ai-advisor"
      ManagedBy   = "Terraform"
      Environment = "localstack"
    }
  }
}

locals {
  name = "fin-ai-advisor-local"
}

module "network" {
  source = "../modules/network"

  name                  = local.name
  vpc_cidr              = "10.0.0.0/16"
  availability_zones    = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnet_cidrs   = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs  = ["10.0.10.0/24", "10.0.20.0/24"]
  database_subnet_cidrs = ["10.0.30.0/24", "10.0.40.0/24"]
  single_nat_gateway    = false # Exercise the highly available layout: one NAT per AZ
}

module "security" {
  source = "../modules/security"

  name   = local.name
  vpc_id = module.network.vpc_id
}

module "app_secrets" {
  source = "../modules/app-secrets"

  name          = local.name
  secret_prefix = "fin-ai-advisor/localstack"
  is_prod       = false
}

module "state_backend" {
  source = "../modules/state-backend"

  name          = local.name
  bucket_name   = "${local.name}-tfstate"
  force_destroy = true # Ephemeral environment: teardown must always succeed
}

module "messaging" {
  source = "../modules/messaging"

  name = local.name
}
