output "alb_dns_name" {
  description = "Public DNS name of the load balancer"
  value       = aws_lb.main.dns_name
}

output "target_group_arns" {
  description = "Target group ARN per service"
  value       = { for k, tg in aws_lb_target_group.service : k => tg.arn }
}

output "listener_rule_arns" {
  description = "Listener rule ARN per service (ECS services depend on them)"
  value       = { for k, rule in aws_lb_listener_rule.service : k => rule.arn }
}
