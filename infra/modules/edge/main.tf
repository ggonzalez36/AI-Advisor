# ==============================================================================
# APPLICATION LOAD BALANCER (public entry point, path-based routing)
#   /api/*  -> portfolio-api (Go)
#   /v1/*   -> ai-service (Python)
#   other   -> 404 (nothing else is exposed: no /metrics, no /docs)
# Plus the alarms on the signals users feel: target 5xx and unhealthy hosts.
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
  https_enabled = var.acm_certificate_arn != ""
  # Routing rules attach to HTTPS when enabled, otherwise to plain HTTP (dev)
  serving_listener_arn = local.https_enabled ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
}

# Accepted (documented) risk: this ALB is the public entry point by design. Exposure is limited
# to 80/443, invalid headers are dropped, and only the configured paths are routed.
#trivy:ignore:AVD-AWS-0053
resource "aws_lb" "main" {
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [var.security_group_id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true # Mitigates HTTP request smuggling / header injection
  enable_deletion_protection = var.is_prod
  idle_timeout               = 60

  tags = {
    Name = "${var.name}-alb"
  }
}

resource "aws_lb_target_group" "service" {
  for_each = var.services

  name                 = "${var.name}-${each.value.short_name}-tg"
  port                 = each.value.port
  protocol             = "HTTP"
  target_type          = "ip" # Required for Fargate (awsvpc networking)
  vpc_id               = var.vpc_id
  deregistration_delay = 30 # Matches the services' graceful shutdown window

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# HTTPS listener (only when a certificate is configured)
resource "aws_lb_listener" "https" {
  count             = local.https_enabled ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\":\"not found\"}"
      status_code  = "404"
    }
  }
}

# HTTP listener: redirects to HTTPS when available; serves traffic directly otherwise (dev only)
#trivy:ignore:AVD-AWS-0054
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = local.https_enabled ? "redirect" : "fixed-response"

    dynamic "redirect" {
      for_each = local.https_enabled ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "fixed_response" {
      for_each = local.https_enabled ? [] : [1]
      content {
        content_type = "application/json"
        message_body = "{\"error\":\"not found\"}"
        status_code  = "404"
      }
    }
  }
}

resource "aws_lb_listener_rule" "service" {
  for_each = var.services

  listener_arn = local.serving_listener_arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.key].arn
  }

  condition {
    path_pattern {
      values = [each.value.path_pattern]
    }
  }
}

# ------------------------------------------------------------------------------
# Alarms
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  for_each = aws_lb_target_group.service

  alarm_name          = "${var.name}-${each.key}-5xx"
  alarm_description   = "More than 10 target 5xx responses in 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_topic_arns
  ok_actions          = var.alarm_topic_arns

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = each.value.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  for_each = aws_lb_target_group.service

  alarm_name          = "${var.name}-${each.key}-unhealthy"
  alarm_description   = "At least one unhealthy target for 3 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = var.alarm_topic_arns
  ok_actions          = var.alarm_topic_arns

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = each.value.arn_suffix
  }
}
