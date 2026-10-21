variable "aws_region" {
  description = "Región de AWS para el despliegue de infraestructura"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Entorno de ejecución (dev, staging, prod)"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "El entorno debe ser 'dev', 'staging' o 'prod'."
  }
}

variable "project_name" {
  description = "Identificador principal del proyecto para etiquetado y nombres"
  type        = string
  default     = "fin-ai-advisor"
}

variable "vpc_cidr" {
  description = "Bloque CIDR para la VPC aislada"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Zonas de disponibilidad para alta disponibilidad Multi-AZ"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "Rangos CIDR para subredes públicas (ALB, NAT Gateway)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Rangos CIDR para subredes privadas (ECS Fargate Services)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.20.0/24"]
}

variable "database_subnet_cidrs" {
  description = "Rangos CIDR para subredes aisladas de base de datos PostgreSQL"
  type        = list(string)
  default     = ["10.0.30.0/24", "10.0.40.0/24"]
}

variable "db_name" {
  description = "Nombre de la base de datos PostgreSQL relacional"
  type        = string
  default     = "fin_ai_advisor_db"
}

variable "db_username" {
  description = "Usuario administrador de la base de datos RDS PostgreSQL"
  type        = string
  default     = "fin_master_admin"
  sensitive   = true
}

variable "db_instance_class" {
  description = "Clase de cómputo para la instancia RDS PostgreSQL"
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage" {
  description = "Capacidad de almacenamiento en GB para RDS con autoscaling"
  type        = number
  default     = 50
}

variable "portfolio_api_cpu" {
  description = "Unidades CPU para el contenedor Go Backend (Fargate)"
  type        = number
  default     = 1024
}

variable "portfolio_api_memory" {
  description = "Memoria en MB para el contenedor Go Backend (Fargate)"
  type        = number
  default     = 2048
}

variable "ai_service_cpu" {
  description = "Unidades CPU para el microservicio Python AI (Fargate)"
  type        = number
  default     = 2048
}

variable "ai_service_memory" {
  description = "Memoria en MB para el microservicio Python AI (Fargate)"
  type        = number
  default     = 4096
}

variable "tags" {
  description = "Etiquetas comunes aplicadas a todos los recursos de AWS"
  type        = map(string)
  default = {
    Project     = "fin-ai-advisor"
    ManagedBy   = "Terraform"
    Environment = "Production"
    Team        = "FinTech-AI-Core"
  }
}
