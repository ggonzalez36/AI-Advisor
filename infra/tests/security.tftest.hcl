# Unit tests for modules/security: the ALB -> ECS -> RDS chain is least privilege.

mock_provider "aws" {
  source = "./tests/mocks"
}

run "least_privilege_chain" {
  command = apply

  module {
    source = "./modules/security"
  }

  variables {
    name   = "test"
    vpc_id = "vpc-12345678"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_services.referenced_security_group_id == aws_security_group.ecs_services.id
    error_message = "The database must only accept traffic from the ECS security group."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_services.from_port == 5432 && aws_vpc_security_group_ingress_rule.db_from_services.to_port == 5432
    error_message = "The database must only expose PostgreSQL (5432)."
  }

  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.services_from_alb : r.referenced_security_group_id == aws_security_group.alb.id])
    error_message = "Services must only accept traffic from the ALB (plus each other)."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.services_https.from_port == 443 && aws_vpc_security_group_egress_rule.services_https.to_port == 443
    error_message = "The only internet egress allowed is HTTPS."
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.services_from_alb)) == toset(["8080", "8000"])
    error_message = "The ALB must reach exactly the two service ports."
  }
}

run "no_internet_ingress_behind_api_gateway" {
  command = apply

  module {
    source = "./modules/security"
  }

  variables {
    name                     = "test"
    vpc_id                   = "vpc-12345678"
    allow_public_alb_ingress = false
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_http) == 0 && length(aws_vpc_security_group_ingress_rule.alb_https) == 0
    error_message = "Behind API Gateway the ALB must not accept traffic from the internet."
  }
}
