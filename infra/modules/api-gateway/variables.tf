variable "name" {
  description = "Name prefix for every resource (project-environment)"
  type        = string
}

variable "is_prod" {
  description = "Enables deletion protection on the reviewer user pool"
  type        = bool
}

variable "vpc_id" {
  description = "VPC of the VPC Link"
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets where the VPC Link places its network interfaces"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group of the internal ALB (gets an ingress rule from the VPC Link)"
  type        = string
}

variable "alb_listener_arn" {
  description = "Listener the VPC Link integration forwards to"
  type        = string
}

variable "alb_listener_port" {
  description = "Port of that listener"
  type        = number
  default     = 80
}

variable "public_route_keys" {
  description = "Routes forwarded without a JWT (the services keep their own validation)"
  type        = list(string)
  default     = ["ANY /api/{proxy+}", "ANY /v1/{proxy+}"]
}

variable "throttling_rate_limit" {
  description = "Steady-state requests per second allowed across the stage"
  type        = number
  default     = 50

  validation {
    condition     = var.throttling_rate_limit > 0
    error_message = "throttling_rate_limit must be positive."
  }
}

variable "throttling_burst_limit" {
  description = "Maximum burst of concurrent requests"
  type        = number
  default     = 100

  validation {
    condition     = var.throttling_burst_limit > 0
    error_message = "throttling_burst_limit must be positive."
  }
}

variable "log_retention_days" {
  description = "Retention for the access log group"
  type        = number
  default     = 30
}
