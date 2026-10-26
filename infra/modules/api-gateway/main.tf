# ==============================================================================
# API GATEWAY (HTTP API): the only public entry point
#
#   client ──HTTPS──▶ API Gateway ──VPC Link──▶ internal ALB ──▶ ECS services
#                     · throttling per stage (managed, shared by every replica)
#                     · JWT authorizer (Cognito) on the human-review route
#                     · JSON access logs
#
# The ALB becomes internal: it no longer accepts traffic from the internet, only from the
# VPC Link security group. Infrastructure only: the AI service still runs its own rate
# limiter and reviewer tokens; with the authorizer, reviewer identity would come from the
# validated JWT claims instead (pending application change).
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

# ------------------------------------------------------------------------------
# Private connectivity: VPC Link -> internal ALB
# ------------------------------------------------------------------------------

resource "aws_security_group" "vpc_link" {
  name        = "${var.name}-apigw-vpclink-sg"
  description = "API Gateway VPC Link: may only reach the internal ALB"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-apigw-vpclink-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "vpc_link_to_alb" {
  security_group_id            = aws_security_group.vpc_link.id
  description                  = "Forward to the internal ALB listener"
  ip_protocol                  = "tcp"
  from_port                    = var.alb_listener_port
  to_port                      = var.alb_listener_port
  referenced_security_group_id = var.alb_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_vpc_link" {
  security_group_id            = var.alb_security_group_id
  description                  = "Traffic from API Gateway (VPC Link) only"
  ip_protocol                  = "tcp"
  from_port                    = var.alb_listener_port
  to_port                      = var.alb_listener_port
  referenced_security_group_id = aws_security_group.vpc_link.id
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.name}-vpc-link"
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpc_link.id]
}

# ------------------------------------------------------------------------------
# Reviewer identity: Cognito user pool (no self sign-up; reviewers are provisioned)
# ------------------------------------------------------------------------------

resource "aws_cognito_user_pool" "reviewers" {
  name                = "${var.name}-reviewers"
  deletion_protection = var.is_prod ? "ACTIVE" : "INACTIVE"
  mfa_configuration   = "ON"

  software_token_mfa_configuration {
    enabled = true
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 1
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "admin_only"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_client" "reviewer_app" {
  name                          = "${var.name}-reviewer-app"
  user_pool_id                  = aws_cognito_user_pool.reviewers.id
  generate_secret               = false
  explicit_auth_flows           = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  access_token_validity         = 60 # minutes
  id_token_validity             = 60
  refresh_token_validity        = 1 # days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

# ------------------------------------------------------------------------------
# HTTP API, integration, authorizer and routes
# ------------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-api"
  protocol_type = "HTTP"
  description   = "Public entry point for ${var.name}"
}

resource "aws_apigatewayv2_integration" "alb" {
  api_id               = aws_apigatewayv2_api.this.id
  integration_type     = "HTTP_PROXY"
  integration_method   = "ANY"
  connection_type      = "VPC_LINK"
  connection_id        = aws_apigatewayv2_vpc_link.this.id
  integration_uri      = var.alb_listener_arn
  timeout_milliseconds = 29000
}

resource "aws_apigatewayv2_authorizer" "reviewers" {
  api_id           = aws_apigatewayv2_api.this.id
  name             = "cognito-reviewers"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.reviewer_app.id]
    issuer   = "https://${aws_cognito_user_pool.reviewers.endpoint}"
  }
}

# The most specific route wins: the review route requires a JWT, the rest pass through
# (portfolio-api and the advice endpoints keep their own validation and rate limits).
resource "aws_apigatewayv2_route" "public" {
  for_each = toset(var.public_route_keys)

  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

resource "aws_apigatewayv2_route" "review" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "POST /v1/advice/{thread_id}/review"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.reviewers.id
}

# ------------------------------------------------------------------------------
# Stage: managed throttling + JSON access logs
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "access" {
  name              = "/apigw/${var.name}/access"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit   = var.throttling_burst_limit
    throttling_rate_limit    = var.throttling_rate_limit
    detailed_metrics_enabled = true
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      latencyMs      = "$context.responseLatency"
      integrationErr = "$context.integrationErrorMessage"
      authorizerErr  = "$context.authorizer.error"
    })
  }
}
