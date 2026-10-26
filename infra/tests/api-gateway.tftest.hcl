# Unit tests for modules/api-gateway: private integration, managed throttling, JWT on review.

mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  name                  = "test"
  is_prod               = false
  vpc_id                = "vpc-12345678"
  private_subnet_ids    = ["subnet-a", "subnet-b"]
  alb_security_group_id = "sg-alb"
  alb_listener_arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/test/0123456789abcdef/http"
}

run "reaches_the_alb_privately" {
  command = apply

  module {
    source = "./modules/api-gateway"
  }

  assert {
    condition     = aws_apigatewayv2_integration.alb.connection_type == "VPC_LINK" && aws_apigatewayv2_integration.alb.integration_uri == var.alb_listener_arn
    error_message = "API Gateway must reach the internal ALB through the VPC Link."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_from_vpc_link.referenced_security_group_id == aws_security_group.vpc_link.id
    error_message = "The ALB must accept traffic from the VPC Link security group only."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.vpc_link_to_alb.referenced_security_group_id == var.alb_security_group_id
    error_message = "The VPC Link may only reach the ALB."
  }
}

run "review_route_requires_a_cognito_jwt" {
  command = apply

  module {
    source = "./modules/api-gateway"
  }

  assert {
    condition     = aws_apigatewayv2_route.review.authorization_type == "JWT" && aws_apigatewayv2_route.review.authorizer_id == aws_apigatewayv2_authorizer.reviewers.id
    error_message = "Approving a recommendation must require a validated JWT."
  }

  assert {
    condition     = one(aws_apigatewayv2_authorizer.reviewers.jwt_configuration).audience == toset([aws_cognito_user_pool_client.reviewer_app.id])
    error_message = "The JWT audience must be the reviewer app client."
  }

  assert {
    condition     = aws_cognito_user_pool.reviewers.mfa_configuration == "ON" && one(aws_cognito_user_pool.reviewers.admin_create_user_config).allow_admin_create_user_only
    error_message = "Reviewers need MFA and cannot self-register."
  }
}

run "stage_throttles_and_logs" {
  command = apply

  module {
    source = "./modules/api-gateway"
  }

  assert {
    condition     = one(aws_apigatewayv2_stage.default.default_route_settings).throttling_rate_limit == 50 && one(aws_apigatewayv2_stage.default.default_route_settings).throttling_burst_limit == 100
    error_message = "The stage must apply managed throttling."
  }

  assert {
    condition     = one(aws_apigatewayv2_stage.default.access_log_settings).destination_arn == aws_cloudwatch_log_group.access.arn
    error_message = "Every request must be written to the access log."
  }
}

run "rejects_non_positive_throttling" {
  command = plan

  module {
    source = "./modules/api-gateway"
  }

  variables {
    throttling_rate_limit = 0
  }

  expect_failures = [var.throttling_rate_limit]
}
