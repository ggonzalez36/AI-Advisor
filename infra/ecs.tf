# ==============================================================================
# ECS FARGATE: cluster, service discovery, task definitions, services, autoscaling
# ==============================================================================

resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${local.name}-ecs-cluster"
  }
}

resource "aws_cloudwatch_log_group" "portfolio_api" {
  name              = "/ecs/${local.name}/portfolio-api"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "ai_service" {
  name              = "/ecs/${local.name}/ai-service"
  retention_in_days = 30
}

# Private DNS so ai-service reaches portfolio-api inside the VPC (no hairpin through the ALB)
resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = "${var.project_name}.internal"
  description = "Service discovery for ${local.name}"
  vpc         = aws_vpc.main.id
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

locals {
  portfolio_api_internal_url = "http://portfolio-api.${aws_service_discovery_private_dns_namespace.internal.name}:8080"

  # ANTHROPIC_API_KEY is only injected when the real LLM provider is enabled
  ai_service_secrets = concat(
    [{ name = "REVIEWER_TOKENS", valueFrom = "${aws_secretsmanager_secret.ai_service.arn}:REVIEWER_TOKENS::" }],
    var.llm_provider == "anthropic" ? [{ name = "ANTHROPIC_API_KEY", valueFrom = "${aws_secretsmanager_secret.ai_service.arn}:ANTHROPIC_API_KEY::" }] : [],
  )
}

# ---------------------------------------------------------------------------
# Task definitions
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "portfolio_api" {
  family                   = "${local.name}-portfolio-api"
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
    image                  = "${aws_ecr_repository.portfolio_api.repository_url}:${var.image_tag}"
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
        awslogs-group         = aws_cloudwatch_log_group.portfolio_api.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "portfolio-api"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "ai_service" {
  family                   = "${local.name}-ai-service"
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
    image        = "${aws_ecr_repository.ai_service.repository_url}:${var.image_tag}"
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
        awslogs-group         = aws_cloudwatch_log_group.ai_service.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "ai-service"
      }
    }
  }])
}

# ---------------------------------------------------------------------------
# Services (private subnets, no public IPs, automatic rollback on failed deploys)
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "portfolio_api" {
  name                              = "portfolio-api"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.portfolio_api.arn
  desired_count                     = var.min_tasks
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 30
  enable_execute_command            = false

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_services.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.portfolio_api.arn
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

  depends_on = [aws_lb_listener_rule.portfolio_api]
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
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_services.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ai_service.arn
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

  depends_on = [aws_lb_listener_rule.ai_service]
}

# ---------------------------------------------------------------------------
# Autoscaling: target tracking on CPU
# ---------------------------------------------------------------------------

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
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each = aws_appautoscaling_target.service

  name               = "${local.name}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = each.value.service_namespace
  scalable_dimension = each.value.scalable_dimension
  resource_id        = each.value.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
