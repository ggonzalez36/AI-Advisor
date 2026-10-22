output "ai_service_secret_arn" {
  description = "Secret to populate with REVIEWER_TOKENS (and ANTHROPIC_API_KEY if enabled)"
  value       = aws_secretsmanager_secret.ai_service.arn
}

output "ai_service_secret_name" {
  description = "Name of the AI service secret"
  value       = aws_secretsmanager_secret.ai_service.name
}
