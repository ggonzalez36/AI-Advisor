output "alb_dns_name" {
  description = "Public DNS name of the load balancer"
  value       = aws_lb.main.dns_name
}

output "vpc_id" {
  description = "ID of the created VPC"
  value       = aws_vpc.main.id
}

output "rds_endpoint" {
  description = "PostgreSQL connection endpoint"
  value       = aws_db_instance.postgres.endpoint
}

output "ecr_portfolio_api_url" {
  description = "ECR registry URL for portfolio-api (Go)"
  value       = aws_ecr_repository.portfolio_api.repository_url
}

output "ecr_ai_service_url" {
  description = "ECR registry URL for ai-service (Python)"
  value       = aws_ecr_repository.ai_service.repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS Fargate cluster"
  value       = aws_ecs_cluster.main.name
}

output "ai_service_secret_arn" {
  description = "Secret to populate with REVIEWER_TOKENS (and ANTHROPIC_API_KEY if enabled)"
  value       = aws_secretsmanager_secret.ai_service.arn
}
