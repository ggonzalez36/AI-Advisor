variable "endpoint" {
  description = "LocalStack edge endpoint"
  type        = string
  default     = "http://localhost:4566"
}

variable "aws_region" {
  description = "Region emulated by LocalStack"
  type        = string
  default     = "us-east-1"
}
