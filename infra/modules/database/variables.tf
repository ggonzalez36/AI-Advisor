variable "name" {
  description = "Name prefix for every resource (project-environment)"
  type        = string
}

variable "secret_prefix" {
  description = "Secrets Manager path prefix (project/environment)"
  type        = string
}

variable "is_prod" {
  description = "Enables Multi-AZ, deletion protection, final snapshot and a secret recovery window"
  type        = bool
}

variable "subnet_ids" {
  description = "Isolated database subnets (at least two AZs)"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group that only admits the application tier"
  type        = string
}

variable "db_name" {
  description = "Name of the PostgreSQL database"
  type        = string
}

variable "db_username" {
  description = "Admin username"
  type        = string
  sensitive   = true
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
}

variable "allocated_storage" {
  description = "Initial storage in GB"
  type        = number
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GB"
  type        = number
  default     = 200

  validation {
    condition     = var.max_allocated_storage >= 20
    error_message = "max_allocated_storage must be at least 20 GB."
  }
}

variable "backup_retention_days" {
  description = "Automated backup retention"
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "Backups must be kept between 7 and 35 days."
  }
}
