# Unit tests for modules/compute: secrets injection, network placement, autoscaling bounds.

mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  name               = "test"
  project_name       = "fin-ai-advisor"
  aws_region         = "us-east-1"
  vpc_id             = "vpc-12345678"
  private_subnet_ids = ["subnet-a", "subnet-b"]
  security_group_id  = "sg-ecs"
  repository_urls    = { "portfolio-api" = "repo/api", "ai-service" = "repo/ai" }
  image_tag          = "abc123"
  target_group_arns = {
    "portfolio-api" = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/api/0123456789abcdef"
    "ai-service"    = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/ai/0123456789abcdef"
  }
  listener_rule_arns    = { "portfolio-api" = "rule-api", "ai-service" = "rule-ai" }
  ai_service_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:ai"
  readable_secret_arns  = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:ai"]
  llm_provider          = "fake"
  portfolio_api_cpu     = 512
  portfolio_api_memory  = 1024
  ai_service_cpu        = 1024
  ai_service_memory     = 2048
  min_tasks             = 2
  max_tasks             = 6
}

run "fake_llm_needs_no_api_key" {
  command = apply

  module {
    source = "./modules/compute"
  }

  assert {
    condition     = !strcontains(aws_ecs_task_definition.ai_service.container_definitions, "ANTHROPIC_API_KEY")
    error_message = "The API key must not be injected when the fake LLM is used."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.portfolio_api.container_definitions)[0].image == "repo/api:abc123"
    error_message = "The task must run the immutable image tag that was deployed."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.portfolio_api.container_definitions)[0].readonlyRootFilesystem
    error_message = "portfolio-api must run with a read-only root filesystem."
  }
}

run "anthropic_injects_api_key_from_secrets_manager" {
  command = apply

  module {
    source = "./modules/compute"
  }

  variables {
    llm_provider = "anthropic"
  }

  assert {
    condition     = contains([for s in jsondecode(aws_ecs_task_definition.ai_service.container_definitions)[0].secrets : s.name], "ANTHROPIC_API_KEY")
    error_message = "The API key must come from Secrets Manager when Claude is enabled."
  }
}

run "tasks_stay_private_and_roll_back" {
  command = apply

  module {
    source = "./modules/compute"
  }

  assert {
    condition     = !aws_ecs_service.portfolio_api.network_configuration[0].assign_public_ip && !aws_ecs_service.ai_service.network_configuration[0].assign_public_ip
    error_message = "Tasks must never get a public IP."
  }

  assert {
    condition     = aws_ecs_service.portfolio_api.deployment_circuit_breaker[0].rollback && aws_ecs_service.ai_service.deployment_circuit_breaker[0].rollback
    error_message = "Failed deployments must roll back automatically."
  }
}

run "rejects_max_tasks_below_min_tasks" {
  command = plan

  module {
    source = "./modules/compute"
  }

  variables {
    min_tasks = 4
    max_tasks = 2
  }

  expect_failures = [aws_appautoscaling_target.service]
}
