# ==============================================================================
# APPLICATION LOAD BALANCER (public entry point, path-based routing)
#   /api/*  -> portfolio-api (Go)
#   /v1/*   -> ai-service (Python)
#   other   -> 404 (nothing else is exposed: no /metrics, no /docs)
# ==============================================================================

locals {
  https_enabled = var.acm_certificate_arn != ""
}

# Accepted (documented) risk: this ALB is the public entry point by design. Exposure is limited
# to 80/443, invalid headers are dropped, and only /api/* and /v1/* are routed.
#trivy:ignore:AVD-AWS-0053
resource "aws_lb" "main" {
  name                       = "${local.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  drop_invalid_header_fields = true # Mitigates HTTP request smuggling / header injection
  enable_deletion_protection = local.is_prod
  idle_timeout               = 60

  tags = {
    Name = "${local.name}-alb"
  }
}

resource "aws_lb_target_group" "portfolio_api" {
  name                 = "${local.name}-api-tg"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip" # Required for Fargate (awsvpc networking)
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30 # Matches the service's graceful shutdown window

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "ai_service" {
  name                 = "${local.name}-ai-tg"
  port                 = 8000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

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

locals {
  # Routing rules attach to HTTPS when enabled, otherwise to plain HTTP (dev)
  serving_listener_arn = local.https_enabled ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
}

resource "aws_lb_listener_rule" "portfolio_api" {
  listener_arn = local.serving_listener_arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.portfolio_api.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}

resource "aws_lb_listener_rule" "ai_service" {
  listener_arn = local.serving_listener_arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai_service.arn
  }

  condition {
    path_pattern {
      values = ["/v1/*"]
    }
  }
}
