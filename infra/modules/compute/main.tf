# ==============================================================================
# ECS FARGATE: cluster, IAM, service discovery, task definitions, services, autoscaling
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
  portfolio_api_internal_url = "http://portfolio-api.${aws_service_discovery_private_dns_namespace.internal.name}:8080"

  # ANTHROPIC_API_KEY is only injected when the real LLM provider is enabled
  ai_service_secrets = concat(
    [{ name = "REVIEWER_TOKENS", valueFrom = "${var.ai_service_secret_arn}:REVIEWER_TOKENS::" }],
    var.llm_provider == "anthropic" ? [{ name = "ANTHROPIC_API_KEY", valueFrom = "${var.ai_service_secret_arn}:ANTHROPIC_API_KEY::" }] : [],
  )
}

resource "aws_ecs_cluster" "main" {
  name = "${var.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.name}-ecs-cluster"
  }
}

resource "aws_cloudwatch_log_group" "service" {
  for_each = toset(["portfolio-api", "ai-service"])

  name              = "/ecs/${var.name}/${each.key}"
  retention_in_days = var.log_retention_days
}

# ------------------------------------------------------------------------------
# IAM (least privilege)
# - Execution role: what ECS needs to START a task (pull image, write logs, read secrets)
# - Task role: what the application itself may call at runtime (nothing today)
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${var.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Read access limited to the secrets the tasks reference
data "aws_iam_policy_document" "read_app_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.readable_secret_arns
  }
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name   = "read-app-secrets"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.read_app_secrets.json
}

# Application role: no permissions attached. Add narrowly scoped statements only when a
# service genuinely needs an AWS API (e.g. S3 for model artifacts).
resource "aws_iam_role" "ecs_task" {
  name               = "${var.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ------------------------------------------------------------------------------
# Service discovery: ai-service reaches portfolio-api inside the VPC (no hairpin through the ALB)
# ------------------------------------------------------------------------------

resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = "${var.project_name}.internal"
  description = "Service discovery for ${var.name}"
  vpc         = var.vpc_id
}

resource "aws_service_discovery_service" "portfolio_api" {
  name = "portfolio-api"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.internal.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# ------------------------------------------------------------------------------
# Task definitions
# ------------------------------------------------------------------------------

resource "aws_ecs_task_definition" "portfolio_api" {
  family                   = "${var.name}-portfolio-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.portfolio_api_cpu
  memory                   = var.portfolio_api_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "data" # Ephemeral task storage for SQLite (see infra/README.md: PostgreSQL adapter pending)
  }

  container_definitions = jsonencode([{
    name                   = "portfolio-api"
    image                  = "${var.repository_urls["portfolio-api"]}:${var.image_tag}"
    essential              = true
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "HOST", value = "0.0.0.0" },
      { name = "PORT", value = "8080" },
      { name = "DB_PATH", value = "/data/portfolio.db" },
    ]
    mountPoints = [{ sourceVolume = "data", containerPath = "/data", readOnly = false }]
    stopTimeout = 30 # Gives the worker pool time to drain on SIGTERM
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service["portfolio-api"].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "portfolio-api"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "ai_service" {
  family                   = "${var.name}-ai-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ai_service_cpu
  memory                   = var.ai_service_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name         = "ai-service"
    image        = "${var.repository_urls["ai-service"]}:${var.image_tag}"
    essential    = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]
    environment = [
      { name = "LLM_PROVIDER", value = var.llm_provider },
      { name = "PORTFOLIO_API_URL", value = local.portfolio_api_internal_url },
    ]
    secrets = local.ai_service_secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service["ai-service"].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "ai-service"
      }
    }
  }])
}

# ------------------------------------------------------------------------------
# Services (private subnets, no public IPs, automatic rollback on failed deploys)
# ------------------------------------------------------------------------------

# ECS rejects a target group that is not yet attached to a listener. depends_on cannot point
# at a variable, so the listener rule ARNs flow through this resource instead.
resource "terraform_data" "listener_rules_ready" {
  input = var.listener_rule_arns
}

resource "aws_ecs_service" "portfolio_api" {
  name                              = "portfolio-api"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.portfolio_api.arn
  desired_count                     = var.min_tasks
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 30
  enable_execute_command            = false

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arns["portfolio-api"]
    container_name   = "portfolio-api"
    container_port   = 8080
  }

  service_registries {
    registry_arn = aws_service_discovery_service.portfolio_api.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count] # Managed by autoscaling after creation
  }

  depends_on = [terraform_data.listener_rules_ready]
}

resource "aws_ecs_service" "ai_service" {
  name                              = "ai-service"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.ai_service.arn
  desired_count                     = var.min_tasks
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 60
  enable_execute_command            = false

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arns["ai-service"]
    container_name   = "ai-service"
    container_port   = 8000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [terraform_data.listener_rules_ready]
}

# ------------------------------------------------------------------------------
# Autoscaling: target tracking on CPU
# ------------------------------------------------------------------------------

resource "aws_appautoscaling_target" "service" {
  for_each = {
    portfolio_api = aws_ecs_service.portfolio_api.name
    ai_service    = aws_ecs_service.ai_service.name
  }

  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${each.value}"
  min_capacity       = var.min_tasks
  max_capacity       = var.max_tasks

  lifecycle {
    precondition {
      condition     = var.max_tasks >= var.min_tasks
      error_message = "max_tasks must be greater than or equal to min_tasks."
    }
  }
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each = aws_appautoscaling_target.service

  name               = "${var.name}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = each.value.service_namespace
  scalable_dimension = each.value.scalable_dimension
  resource_id        = each.value.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
