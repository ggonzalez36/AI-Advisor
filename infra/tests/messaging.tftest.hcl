# Unit tests for modules/messaging: durable FIFO queue with DLQ and event fan-out.

mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  name = "test"
}

run "order_queue_is_fifo_with_a_dead_letter_queue" {
  command = apply

  module {
    source = "./modules/messaging"
  }

  assert {
    condition     = aws_sqs_queue.orders.fifo_queue && aws_sqs_queue.orders_dlq.fifo_queue
    error_message = "The order queue and its DLQ must be FIFO (per-portfolio ordering, deduplication)."
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.orders.redrive_policy).deadLetterTargetArn == aws_sqs_queue.orders_dlq.arn
    error_message = "Failed orders must move to the order DLQ."
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.orders.redrive_policy).maxReceiveCount == 5
    error_message = "A message should be retried 5 times before going to the DLQ."
  }

  assert {
    condition     = aws_sqs_queue.orders.deduplication_scope == "messageGroup" && aws_sqs_queue.orders.fifo_throughput_limit == "perMessageGroupId"
    error_message = "Deduplication and throughput must be scoped per portfolio (message group)."
  }
}

run "everything_is_encrypted_with_the_messaging_key" {
  command = apply

  module {
    source = "./modules/messaging"
  }

  assert {
    condition = alltrue(concat(
      [aws_sqs_queue.orders.kms_master_key_id == aws_kms_key.messaging.arn],
      [aws_sqs_queue.orders_dlq.kms_master_key_id == aws_kms_key.messaging.arn],
      [for q in aws_sqs_queue.subscriber : q.kms_master_key_id == aws_kms_key.messaging.arn],
      [aws_sns_topic.order_events.kms_master_key_id == aws_kms_key.messaging.arn],
    ))
    error_message = "Every queue and the topic must use the customer-managed key."
  }

  assert {
    condition     = aws_kms_key.messaging.enable_key_rotation
    error_message = "The messaging key must rotate."
  }
}

run "events_fan_out_to_one_queue_per_subscriber" {
  command = apply

  module {
    source = "./modules/messaging"
  }

  assert {
    condition     = toset(keys(aws_sns_topic_subscription.subscriber)) == toset(["audit", "notifications"])
    error_message = "The audit and notifications queues must be subscribed to the order events."
  }

  assert {
    condition     = alltrue([for k, s in aws_sns_topic_subscription.subscriber : s.protocol == "sqs" && s.raw_message_delivery && s.endpoint == aws_sqs_queue.subscriber[k].arn])
    error_message = "Each subscription must deliver the raw event to its own queue."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.dlq_not_empty) == 3
    error_message = "Every DLQ (orders, audit, notifications) needs an alarm."
  }
}

run "rejects_duplicate_subscribers" {
  command = plan

  module {
    source = "./modules/messaging"
  }

  variables {
    event_subscribers = ["audit", "audit"]
  }

  expect_failures = [var.event_subscribers]
}
