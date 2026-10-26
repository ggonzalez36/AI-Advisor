# Unit tests for modules/bedrock-access: private endpoint, least-privilege invoke permission.

mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  name                  = "test"
  aws_region            = "us-east-1"
  vpc_id                = "vpc-12345678"
  private_subnet_ids    = ["subnet-a", "subnet-b"]
  ecs_security_group_id = "sg-ecs"
  task_role_name        = "test-ecs-task"
}

run "bedrock_is_reached_through_a_private_endpoint" {
  command = apply

  module {
    source = "./modules/bedrock-access"
  }

  assert {
    condition     = aws_vpc_endpoint.bedrock_runtime.service_name == "com.amazonaws.us-east-1.bedrock-runtime" && aws_vpc_endpoint.bedrock_runtime.vpc_endpoint_type == "Interface"
    error_message = "Bedrock must be reached through an interface endpoint for bedrock-runtime."
  }

  assert {
    condition     = aws_vpc_endpoint.bedrock_runtime.private_dns_enabled
    error_message = "Private DNS lets the SDK's default hostname resolve to the endpoint."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.endpoint_from_tasks.referenced_security_group_id == var.ecs_security_group_id && aws_vpc_security_group_ingress_rule.endpoint_from_tasks.from_port == 443
    error_message = "Only the ECS tasks may reach the endpoint, on HTTPS."
  }
}

run "the_role_may_only_invoke_anthropic_models" {
  command = apply

  module {
    source = "./modules/bedrock-access"
  }

  assert {
    condition     = aws_iam_role_policy.invoke.role == var.task_role_name
    error_message = "The permission belongs to the application role."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.invoke.statement).resources == toset(["arn:aws:bedrock:us-east-1::foundation-model/anthropic.*"])
    error_message = "The invoke permission must be limited to Anthropic foundation models."
  }

  assert {
    condition     = toset(one(data.aws_iam_policy_document.invoke.statement).actions) == toset(["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"])
    error_message = "Only invoke actions are allowed (no model management)."
  }
}

run "rejects_non_anthropic_models" {
  command = plan

  module {
    source = "./modules/bedrock-access"
  }

  variables {
    model_id_pattern = "*"
  }

  expect_failures = [var.model_id_pattern]
}
