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

output "serving_listener_arn" {
  description = "Listener that carries the routing rules (HTTPS when a certificate is set, HTTP otherwise)"
  value       = local.serving_listener_arn
}

output "serving_listener_port" {
  description = "Port of the serving listener"
  value       = var.acm_certificate_arn != "" ? 443 : 80
}
