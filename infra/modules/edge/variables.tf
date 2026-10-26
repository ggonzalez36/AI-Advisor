variable "name" {
  description = "Name prefix for every resource (project-environment)"
  type        = string
}

variable "is_prod" {
  description = "Enables deletion protection on the load balancer"
  type        = bool
}

variable "vpc_id" {
  description = "VPC of the target groups"
  type        = string
}

variable "internal" {
  description = "Internal ALB (reachable only inside the VPC, e.g. behind API Gateway) instead of internet-facing"
  type        = bool
  default     = false
}

variable "subnet_ids" {
  description = "Subnets for the load balancer (at least two AZs): private when internal, public otherwise"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group of the load balancer"
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM certificate for HTTPS. Empty means HTTP only (dev)."
  type        = string
  default     = ""
}

variable "services" {
  description = "Services routed by path. short_name keeps target group names under 32 characters."
  type = map(object({
    short_name   = string
    port         = number
    path_pattern = string
    priority     = number
  }))

  validation {
    condition     = length(distinct([for s in values(var.services) : s.priority])) == length(var.services)
    error_message = "Each service needs a unique listener rule priority."
  }
}

variable "alarm_topic_arns" {
  description = "SNS topics notified when an alarm changes state"
  type        = list(string)
  default     = []
}
