output "cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "service_names" {
  description = "ECS service names"
  value       = [aws_ecs_service.portfolio_api.name, aws_ecs_service.ai_service.name]
}

output "task_role_name" {
  description = "Application role of the tasks (receives runtime permissions such as Bedrock or SQS)"
  value       = aws_iam_role.ecs_task.name
}
