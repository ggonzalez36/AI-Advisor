variable "name" {
  description = "Name prefix for every resource (project-environment)"
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to"
  type        = string
}

variable "service_ports" {
  description = "Container ports the ALB forwards to"
  type        = list(number)
  default     = [8080, 8000]
}

variable "internal_port" {
  description = "Port services use to call each other inside the VPC (portfolio-api)"
  type        = number
  default     = 8080
}
