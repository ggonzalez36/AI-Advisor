variable "project_name" {
  description = "Repository path prefix"
  type        = string
}

variable "services" {
  description = "One repository is created per service"
  type        = list(string)
}

variable "images_to_keep" {
  description = "Number of images retained per repository"
  type        = number
  default     = 30
}
