variable "name" {
  description = "Name prefix for every resource (project-environment)"
  type        = string
}

variable "event_subscribers" {
  description = "One queue is subscribed to the order-events topic per entry"
  type        = list(string)
  default     = ["audit", "notifications"]

  validation {
    condition     = length(var.event_subscribers) == length(distinct(var.event_subscribers))
    error_message = "Subscriber names must be unique."
  }
}

variable "visibility_timeout_seconds" {
  description = "How long a received message stays hidden while a consumer processes it"
  type        = number
  default     = 60
}

variable "message_retention_seconds" {
  description = "How long an unconsumed message is kept"
  type        = number
  default     = 345600 # 4 days
}

variable "max_receive_count" {
  description = "Failed receives before a message moves to its dead-letter queue"
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000
    error_message = "max_receive_count must be between 1 and 1000."
  }
}

variable "alarm_topic_arns" {
  description = "SNS topics notified when a dead-letter queue receives messages"
  type        = list(string)
  default     = []
}
