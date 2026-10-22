# Unit tests for modules/edge: HTTPS toggling and path-based routing.

mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  name              = "test"
  is_prod           = false
  vpc_id            = "vpc-12345678"
  public_subnet_ids = ["subnet-a", "subnet-b"]
  security_group_id = "sg-alb"
  services = {
    "portfolio-api" = { short_name = "api", port = 8080, path_pattern = "/api/*", priority = 10 }
    "ai-service"    = { short_name = "ai", port = 8000, path_pattern = "/v1/*", priority = 20 }
  }
}

run "http_only_without_certificate" {
  command = apply

  module {
    source = "./modules/edge"
  }

  assert {
    condition     = length(aws_lb_listener.https) == 0
    error_message = "No HTTPS listener is expected without a certificate."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "fixed-response"
    error_message = "Unknown paths must get a 404, not reach a service."
  }

  assert {
    condition     = alltrue([for r in aws_lb_listener_rule.service : r.listener_arn == aws_lb_listener.http.arn])
    error_message = "Routing rules must attach to the HTTP listener in dev."
  }
}

run "https_redirect_with_certificate" {
  command = apply

  module {
    source = "./modules/edge"
  }

  variables {
    acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/test"
  }

  # Distinct ARN, so the assertion below can tell the two listeners apart
  override_resource {
    target = aws_lb_listener.https
    values = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/test/0123456789abcdef/https"
    }
  }

  assert {
    condition     = length(aws_lb_listener.https) == 1 && aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "HTTPS must use a TLS 1.3 policy."
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "redirect"
    error_message = "HTTP must redirect to HTTPS when a certificate exists."
  }

  assert {
    condition     = alltrue([for r in aws_lb_listener_rule.service : r.listener_arn == aws_lb_listener.https[0].arn])
    error_message = "Routing rules must attach to the HTTPS listener."
  }
}

run "alb_hardening" {
  command = apply

  module {
    source = "./modules/edge"
  }

  assert {
    condition     = aws_lb.main.drop_invalid_header_fields
    error_message = "The ALB must drop invalid headers (request smuggling)."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.target_5xx) == 2 && length(aws_cloudwatch_metric_alarm.unhealthy_hosts) == 2
    error_message = "Each service needs a 5xx alarm and an unhealthy-hosts alarm."
  }
}

run "rejects_duplicate_rule_priorities" {
  command = plan

  module {
    source = "./modules/edge"
  }

  variables {
    services = {
      "a" = { short_name = "a", port = 8080, path_pattern = "/a/*", priority = 10 }
      "b" = { short_name = "b", port = 8000, path_pattern = "/b/*", priority = 10 }
    }
  }

  expect_failures = [var.services]
}
