variable "aws_region" {
  description = "AWS region for the infrastructure deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "The environment must be 'dev', 'staging', or 'prod'."
  }
}

variable "project_name" {
  description = "Primary project identifier used for tagging and naming"
  type        = string
  default     = "fin-ai-advisor"
}

variable "vpc_cidr" {
  description = "CIDR block for the isolated VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for Multi-AZ high availability"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR ranges for public subnets (ALB, NAT Gateway)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR ranges for private subnets (ECS Fargate Services)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.20.0/24"]
}

variable "database_subnet_cidrs" {
  description = "CIDR ranges for isolated PostgreSQL database subnets"
  type        = list(string)
  default     = ["10.0.30.0/24", "10.0.40.0/24"]
}

variable "db_name" {
  description = "Name of the relational PostgreSQL database"
  type        = string
  default     = "fin_ai_advisor_db"
}

variable "db_username" {
  description = "Admin username for the RDS PostgreSQL database"
  type        = string
  default     = "fin_master_admin"
  sensitive   = true
}

variable "db_instance_class" {
  description = "Compute class for the RDS PostgreSQL instance"
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage" {
  description = "Storage capacity in GB for RDS with autoscaling"
  type        = number
  default     = 50
}

variable "portfolio_api_cpu" {
  description = "CPU units for the Go Backend container (Fargate)"
  type        = number
  default     = 1024
}

variable "portfolio_api_memory" {
  description = "Memory in MB for the Go Backend container (Fargate)"
  type        = number
  default     = 2048
}

variable "ai_service_cpu" {
  description = "CPU units for the Python AI microservice (Fargate)"
  type        = number
  default     = 2048
}

variable "ai_service_memory" {
  description = "Memory in MB for the Python AI microservice (Fargate)"
  type        = number
  default     = 4096
}

variable "tags" {
  description = "Common tags applied to all AWS resources"
  type        = map(string)
  default = {
    Project     = "fin-ai-advisor"
    ManagedBy   = "Terraform"
    Environment = "Production"
    Team        = "FinTech-AI-Core"
  }
}
