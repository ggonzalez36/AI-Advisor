output "orders_queue_url" {
  description = "URL of the FIFO order queue"
  value       = aws_sqs_queue.orders.id
}

output "orders_queue_arn" {
  description = "ARN of the FIFO order queue"
  value       = aws_sqs_queue.orders.arn
}

output "orders_dlq_url" {
  description = "URL of the order dead-letter queue"
  value       = aws_sqs_queue.orders_dlq.id
}

output "order_events_topic_arn" {
  description = "SNS topic for order events (executed, compensated, compensation failed)"
  value       = aws_sns_topic.order_events.arn
}

output "subscriber_queue_urls" {
  description = "Queue URL per order-event subscriber"
  value       = { for k, q in aws_sqs_queue.subscriber : k => q.id }
}

output "kms_key_arn" {
  description = "Key that encrypts the queues and the topic (producers need kms:GenerateDataKey)"
  value       = aws_kms_key.messaging.arn
}
