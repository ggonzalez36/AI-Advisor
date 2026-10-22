variable "name" {
  description = "Name prefix for every resource (project-environment)"
  type        = string
}

variable "secret_prefix" {
  description = "Secrets Manager path prefix (project/environment)"
  type        = string
}

variable "is_prod" {
  description = "Keeps a 30-day recovery window in prod; immediate deletion elsewhere"
  type        = bool
}
