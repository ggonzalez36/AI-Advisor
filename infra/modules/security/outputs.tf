output "alb_security_group_id" {
  description = "Security group of the public load balancer"
  value       = aws_security_group.alb.id
}

output "ecs_security_group_id" {
  description = "Security group of the ECS tasks"
  value       = aws_security_group.ecs_services.id
}

output "rds_security_group_id" {
  description = "Security group of the database"
  value       = aws_security_group.rds.id
}
