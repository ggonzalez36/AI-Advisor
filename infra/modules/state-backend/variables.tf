variable "name" {
  description = "Name prefix for the lock table and KMS alias"
  type        = string
}

variable "bucket_name" {
  description = "Globally unique name of the state bucket"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name (3-63 lowercase characters)."
  }
}

variable "force_destroy" {
  description = "Allow deleting the bucket with objects inside (only for ephemeral test environments)"
  type        = bool
  default     = false
}

variable "noncurrent_version_days" {
  description = "Days to keep superseded state versions"
  type        = number
  default     = 90
}
