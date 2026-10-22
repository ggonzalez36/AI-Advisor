variable "name" {
  description = "Name prefix for every resource (project-environment)"
  type        = string
}

variable "project_name" {
  description = "Used for the private DNS namespace (<project>.internal)"
  type        = string
}

variable "aws_region" {
  description = "Region for the awslogs log driver"
  type        = string
}

variable "vpc_id" {
  description = "VPC for service discovery"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets where tasks run"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group of the tasks"
  type        = string
}

variable "repository_urls" {
  description = "ECR repository URL per service (keys: portfolio-api, ai-service)"
  type        = map(string)
}

variable "image_tag" {
  description = "Container image tag to deploy (immutable, e.g. the git SHA)"
  type        = string
}

variable "target_group_arns" {
  description = "ALB target group ARN per service"
  type        = map(string)
}

variable "listener_rule_arns" {
  description = "Listener rule ARNs; services are created only after these exist"
  type        = map(string)
}

variable "ai_service_secret_arn" {
  description = "Secret with REVIEWER_TOKENS and, optionally, ANTHROPIC_API_KEY"
  type        = string
}

variable "readable_secret_arns" {
  description = "Secrets the execution role may read (nothing else)"
  type        = list(string)
}

variable "llm_provider" {
  description = "LLM backend for the AI service: 'fake' or 'anthropic'"
  type        = string
}

variable "portfolio_api_cpu" {
  description = "CPU units for portfolio-api"
  type        = number
}

variable "portfolio_api_memory" {
  description = "Memory in MB for portfolio-api"
  type        = number
}

variable "ai_service_cpu" {
  description = "CPU units for ai-service"
  type        = number
}

variable "ai_service_memory" {
  description = "Memory in MB for ai-service"
  type        = number
}

variable "min_tasks" {
  description = "Minimum tasks per service"
  type        = number
}

variable "max_tasks" {
  description = "Maximum tasks per service"
  type        = number
}

variable "cpu_target_percent" {
  description = "Average CPU the autoscaler aims for"
  type        = number
  default     = 60
}

variable "log_retention_days" {
  description = "Retention for the service log groups"
  type        = number
  default     = 30
}
