# ==============================================================================
# BEDROCK ACCESS: call Claude through AWS instead of over the internet
#
#   ai-service task ──443──▶ VPC interface endpoint (bedrock-runtime) ──▶ Bedrock
#
# · Traffic to the model stays on the AWS network (PrivateLink); it does not need the NAT.
# · Authentication is the task's IAM role: no API key stored in Secrets Manager.
# · The role may invoke Anthropic models only (least privilege by provider).
#
# Infrastructure only: the AI service still calls the Anthropic API directly. Switching
# means adding a Bedrock adapter behind the existing LLMClient port (pending).
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

resource "aws_security_group" "endpoint" {
  name        = "${var.name}-bedrock-endpoint-sg"
  description = "Bedrock runtime endpoint: HTTPS from the ECS tasks only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-bedrock-endpoint-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoint_from_tasks" {
  security_group_id            = aws_security_group.endpoint.id
  description                  = "HTTPS from the ECS tasks"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = var.ecs_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_endpoint" {
  security_group_id            = var.ecs_security_group_id
  description                  = "HTTPS to the Bedrock runtime endpoint"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.endpoint.id
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = true # The SDK's default Bedrock hostname resolves to the endpoint

  tags = {
    Name = "${var.name}-bedrock-runtime"
  }
}

# Invoke permission for Anthropic foundation models only. Narrow `model_id_pattern` to the
# exact model ID once it is fixed, to remove access to every other Anthropic model.
data "aws_iam_policy_document" "invoke" {
  statement {
    sid = "InvokeAnthropicModels"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["arn:aws:bedrock:${var.aws_region}::foundation-model/${var.model_id_pattern}"]
  }
}

resource "aws_iam_role_policy" "invoke" {
  name   = "invoke-bedrock-anthropic"
  role   = var.task_role_name
  policy = data.aws_iam_policy_document.invoke.json
}
