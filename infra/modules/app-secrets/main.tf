# ==============================================================================
# APPLICATION SECRETS
# The secret is created empty. Its value is set out-of-band (never in code or state), e.g.
#   aws secretsmanager put-secret-value --secret-id <arn> --secret-string '{"REVIEWER_TOKENS":"..."}'
# as JSON with REVIEWER_TOKENS and, when llm_provider = "anthropic", ANTHROPIC_API_KEY.
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

resource "aws_secretsmanager_secret" "ai_service" {
  name                    = "${var.secret_prefix}/ai-service"
  description             = "Runtime configuration for the AI service"
  recovery_window_in_days = var.is_prod ? 30 : 0

  tags = {
    Name = "${var.name}-ai-service-secret"
  }
}
