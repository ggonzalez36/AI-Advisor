variable "name" {
  description = "Name prefix for every resource (project-environment)"
  type        = string
}

variable "aws_region" {
  description = "Region of the Bedrock runtime endpoint"
  type        = string
}

variable "vpc_id" {
  description = "VPC where the interface endpoint is created"
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets for the endpoint's network interfaces (one per AZ)"
  type        = list(string)
}

variable "ecs_security_group_id" {
  description = "Security group of the tasks allowed to call Bedrock"
  type        = string
}

variable "task_role_name" {
  description = "Application role that receives the invoke permission"
  type        = string
}

variable "model_id_pattern" {
  description = "Foundation-model ID (or pattern) the role may invoke"
  type        = string
  default     = "anthropic.*"

  validation {
    condition     = startswith(var.model_id_pattern, "anthropic.")
    error_message = "Only Anthropic models are allowed: the pattern must start with 'anthropic.'."
  }
}
