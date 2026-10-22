# Integration tests for the root module: the whole environment wired together, dev vs. prod.

mock_provider "aws" {
  source = "./tests/mocks"
}
mock_provider "random" {}

run "dev_is_cheap_and_disposable" {
  command = apply

  variables {
    environment = "dev"
  }

  assert {
    condition     = length(module.network.nat_gateway_ids) == 1
    error_message = "dev should share a single NAT gateway."
  }

  assert {
    condition     = length(module.registry.repository_urls) == 2
    error_message = "One ECR repository per service is expected."
  }
}

run "prod_is_highly_available" {
  command = apply

  variables {
    environment = "prod"
  }

  assert {
    condition     = length(module.network.nat_gateway_ids) == 2
    error_message = "prod needs one NAT gateway per AZ."
  }
}

run "prod_can_opt_back_into_a_single_nat" {
  command = plan

  variables {
    environment        = "prod"
    single_nat_gateway = true
  }

  assert {
    condition     = local.single_nat
    error_message = "An explicit single_nat_gateway must override the environment default."
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
}

run "rejects_unknown_llm_provider" {
  command = plan

  variables {
    llm_provider = "gpt"
  }

  expect_failures = [var.llm_provider]
}

run "rejects_invalid_alarm_email" {
  command = plan

  variables {
    alarm_email = "not-an-email"
  }

  expect_failures = [var.alarm_email]
}
