# ==============================================================================
# FIN-AI ADVISOR: AWS ENVIRONMENT (root module)
# Composes the reusable modules in ./modules. The same modules are applied against
# LocalStack in ./localstack, so the network, security and messaging layers are tested for
# real in CI.
#
#   api-gateway ─▶ edge (internal ALB) ─▶ compute (ECS Fargate) ─┬─▶ database (RDS)
#   network · security · registry (ECR) · app-secrets            ├─▶ messaging (SQS, SNS)
#                                                                └─▶ bedrock-access
# ==============================================================================

terraform {
  required_version = ">= 1.7.0" # mock_provider in `terraform test`
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
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
  name          = "${var.project_name}-${var.environment}"
  secret_prefix = "${var.project_name}/${var.environment}"
  is_prod       = var.environment == "prod"
  # One NAT gateway per AZ removes the single point of failure for outbound traffic;
  # a single NAT keeps dev/staging cheaper. The trade-off is explicit and configurable.
  single_nat = coalesce(var.single_nat_gateway, !local.is_prod)

  services = {
    "portfolio-api" = { short_name = "api", port = 8080, path_pattern = "/api/*", priority = 10 }
    "ai-service"    = { short_name = "ai", port = 8000, path_pattern = "/v1/*", priority = 20 }
  }
}

module "network" {
  source = "./modules/network"

  name                  = local.name
  vpc_cidr              = var.vpc_cidr
  availability_zones    = var.availability_zones
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs
  single_nat_gateway    = local.single_nat
}

module "security" {
  source = "./modules/security"

  name          = local.name
  vpc_id        = module.network.vpc_id
  service_ports = [for s in values(local.services) : s.port]
  # API Gateway is the only public entry point; the ALB accepts traffic from its VPC Link only
  allow_public_alb_ingress = false
}

module "app_secrets" {
  source = "./modules/app-secrets"

  name          = local.name
  secret_prefix = local.secret_prefix
  is_prod       = local.is_prod
}

module "database" {
  source = "./modules/database"

  name              = local.name
  secret_prefix     = local.secret_prefix
  is_prod           = local.is_prod
  subnet_ids        = module.network.database_subnet_ids
  security_group_id = module.security.rds_security_group_id
  db_name           = var.db_name
  db_username       = var.db_username
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
}

module "registry" {
  source = "./modules/registry"

  project_name = var.project_name
  services     = keys(local.services)
}

# Alarm notifications, encrypted with a customer-managed key. CloudWatch must be allowed to
# use the key, or encrypted alarms would be silently dropped.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "alarms_key" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchPublishesAlarms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "alarms" {
  description             = "Encrypts the ${local.name} alarm topic"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.alarms_key.json
}

resource "aws_sns_topic" "alarms" {
  name              = "${local.name}-alarms"
  kms_master_key_id = aws_kms_key.alarms.arn
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

module "edge" {
  source = "./modules/edge"

  name                = local.name
  is_prod             = local.is_prod
  vpc_id              = module.network.vpc_id
  internal            = true
  subnet_ids          = module.network.private_subnet_ids
  security_group_id   = module.security.alb_security_group_id
  acm_certificate_arn = var.acm_certificate_arn
  services            = local.services
  alarm_topic_arns    = [aws_sns_topic.alarms.arn]
}

module "compute" {
  source = "./modules/compute"

  name                  = local.name
  project_name          = var.project_name
  aws_region            = var.aws_region
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  security_group_id     = module.security.ecs_security_group_id
  repository_urls       = module.registry.repository_urls
  image_tag             = var.image_tag
  target_group_arns     = module.edge.target_group_arns
  listener_rule_arns    = module.edge.listener_rule_arns
  ai_service_secret_arn = module.app_secrets.ai_service_secret_arn
  readable_secret_arns  = [module.database.credentials_secret_arn, module.app_secrets.ai_service_secret_arn]
  llm_provider          = var.llm_provider
  portfolio_api_cpu     = var.portfolio_api_cpu
  portfolio_api_memory  = var.portfolio_api_memory
  ai_service_cpu        = var.ai_service_cpu
  ai_service_memory     = var.ai_service_memory
  min_tasks             = var.min_tasks
  max_tasks             = var.max_tasks
}

module "api_gateway" {
  source = "./modules/api-gateway"

  name                   = local.name
  is_prod                = local.is_prod
  vpc_id                 = module.network.vpc_id
  private_subnet_ids     = module.network.private_subnet_ids
  alb_security_group_id  = module.security.alb_security_group_id
  alb_listener_arn       = module.edge.serving_listener_arn
  alb_listener_port      = module.edge.serving_listener_port
  throttling_rate_limit  = var.api_throttling_rate_limit
  throttling_burst_limit = var.api_throttling_burst_limit
}

module "messaging" {
  source = "./modules/messaging"

  name             = local.name
  alarm_topic_arns = [aws_sns_topic.alarms.arn]
}

module "bedrock_access" {
  source = "./modules/bedrock-access"
  count  = var.enable_bedrock_access ? 1 : 0

  name                  = local.name
  aws_region            = var.aws_region
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  ecs_security_group_id = module.security.ecs_security_group_id
  task_role_name        = module.compute.task_role_name
}

# Runtime permissions for the services to use the queue and the topic once integrated:
# produce and consume orders, publish order events, and use the key that encrypts both.
data "aws_iam_policy_document" "task_messaging" {
  statement {
    sid = "OrderQueue"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [module.messaging.orders_queue_arn]
  }

  statement {
    sid       = "PublishOrderEvents"
    actions   = ["sns:Publish"]
    resources = [module.messaging.order_events_topic_arn]
  }

  statement {
    sid       = "UseMessagingKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [module.messaging.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "task_messaging" {
  name   = "use-order-messaging"
  role   = module.compute.task_role_name
  policy = data.aws_iam_policy_document.task_messaging.json
}
