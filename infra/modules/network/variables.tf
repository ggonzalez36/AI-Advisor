variable "name" {
  description = "Name prefix for every resource (project-environment)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "Availability zones; one subnet per tier is created in each"
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required for high availability."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR ranges for public subnets (ALB, NAT), one per AZ"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR ranges for private subnets (ECS tasks), one per AZ"
  type        = list(string)
}

variable "database_subnet_cidrs" {
  description = "CIDR ranges for isolated database subnets, one per AZ"
  type        = list(string)
}

variable "enable_nat_gateway" {
  description = "Create NAT gateways so private subnets have outbound internet access"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "One shared NAT (cheaper) instead of one per AZ (highly available)"
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch Logs"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the flow log group"
  type        = number
  default     = 30
}
