output "api_endpoint" {
  description = "Public HTTPS endpoint (API Gateway): the only way in"
  value       = module.api_gateway.api_endpoint
}

output "alb_dns_name" {
  description = "Internal DNS name of the load balancer (reachable only inside the VPC)"
  value       = module.edge.alb_dns_name
}

output "vpc_id" {
  description = "ID of the created VPC"
  value       = module.network.vpc_id
}

output "rds_endpoint" {
  description = "PostgreSQL connection endpoint"
  value       = module.database.endpoint
}

output "ecr_repository_urls" {
  description = "ECR repository URL per service"
  value       = module.registry.repository_urls
}

output "ecs_cluster_name" {
  description = "Name of the ECS Fargate cluster"
  value       = module.compute.cluster_name
}

output "ai_service_secret_arn" {
  description = "Secret to populate with REVIEWER_TOKENS (and ANTHROPIC_API_KEY if enabled)"
  value       = module.app_secrets.ai_service_secret_arn
}

output "alarm_topic_arn" {
  description = "SNS topic that receives every CloudWatch alarm"
  value       = aws_sns_topic.alarms.arn
}

output "reviewer_user_pool_id" {
  description = "Cognito user pool for human reviewers"
  value       = module.api_gateway.reviewer_user_pool_id
}

output "orders_queue_url" {
  description = "FIFO order queue"
  value       = module.messaging.orders_queue_url
}

output "order_events_topic_arn" {
  description = "SNS topic for order events"
  value       = module.messaging.order_events_topic_arn
}
