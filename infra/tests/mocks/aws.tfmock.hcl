# Realistic values for computed attributes. The mocked provider still validates its inputs
# (ARN formats, JSON policies), so random strings are not enough for these.

mock_data "aws_iam_policy_document" {
  defaults = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

mock_resource "aws_lb" {
  defaults = {
    arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/test/0123456789abcdef"
    arn_suffix = "app/test/0123456789abcdef"
  }
}

mock_resource "aws_lb_target_group" {
  defaults = {
    arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/test/0123456789abcdef"
    arn_suffix = "targetgroup/test/0123456789abcdef"
  }
}

mock_resource "aws_lb_listener" {
  defaults = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/test/0123456789abcdef/http"
  }
}

mock_resource "aws_iam_role" {
  defaults = {
    arn = "arn:aws:iam::123456789012:role/test"
  }
}

mock_resource "aws_cloudwatch_log_group" {
  defaults = {
    arn = "arn:aws:logs:us-east-1:123456789012:log-group:test"
  }
}

mock_resource "aws_sns_topic" {
  defaults = {
    arn = "arn:aws:sns:us-east-1:123456789012:test-alarms"
  }
}

mock_resource "aws_kms_key" {
  defaults = {
    arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  }
}

mock_resource "aws_secretsmanager_secret" {
  defaults = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-AbCdEf"
  }
}

mock_resource "aws_service_discovery_service" {
  defaults = {
    arn = "arn:aws:servicediscovery:us-east-1:123456789012:service/srv-test"
  }
}

mock_resource "aws_ecs_task_definition" {
  defaults = {
    arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/test:1"
  }
}

mock_resource "aws_ecs_cluster" {
  defaults = {
    arn = "arn:aws:ecs:us-east-1:123456789012:cluster/test"
  }
}

mock_resource "aws_sqs_queue" {
  defaults = {
    arn = "arn:aws:sqs:us-east-1:123456789012:test-queue"
  }
}

mock_resource "aws_cognito_user_pool" {
  defaults = {
    endpoint = "cognito-idp.us-east-1.amazonaws.com/us-east-1_TestPool"
  }
}
