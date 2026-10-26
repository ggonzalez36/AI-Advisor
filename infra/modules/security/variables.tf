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

variable "allow_public_alb_ingress" {
  description = "Open 80/443 on the ALB to the internet. False when API Gateway is the entry point."
  type        = bool
  default     = true
}
