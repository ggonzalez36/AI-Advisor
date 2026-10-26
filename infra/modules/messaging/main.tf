# ==============================================================================
# MESSAGING: durable order queue (SQS FIFO + DLQ) and order-event fan-out (SNS -> SQS)
#
#   orders.fifo ──(5 failed receives)──▶ orders-dlq.fifo ──▶ alarm
#   order-events (SNS) ──▶ audit queue
#                      └─▶ notifications queue      (each with its own DLQ)
#
# Infrastructure only: today portfolio-api still dispatches through its in-process channel
# and outbox relay. The queue replaces that channel when the service runs as several
# replicas; the topic is the publish/subscribe (Observer) side for order events.
# Everything is encrypted with one customer-managed key that SNS is allowed to use, or
# deliveries from the topic to the encrypted queues would be dropped silently.
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "key" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "SnsDeliversToEncryptedQueues"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "messaging" {
  description             = "Encrypts the ${var.name} queues and order-event topic"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.key.json
}

# ------------------------------------------------------------------------------
# Order queue (FIFO): ordering per portfolio and deduplication per idempotency key
# ------------------------------------------------------------------------------

resource "aws_sqs_queue" "orders_dlq" {
  name                      = "${var.name}-orders-dlq.fifo"
  fifo_queue                = true
  message_retention_seconds = 1209600 # 14 days, the maximum: time to investigate
  kms_master_key_id         = aws_kms_key.messaging.arn
}

resource "aws_sqs_queue" "orders" {
  name       = "${var.name}-orders.fifo"
  fifo_queue = true
  # MessageGroupId = portfolio_id keeps each portfolio's orders in sequence while different
  # portfolios are processed in parallel. MessageDeduplicationId = idempotency key drops
  # duplicates for 5 minutes; the database UNIQUE constraint still guards beyond that.
  deduplication_scope        = "messageGroup"
  fifo_throughput_limit      = "perMessageGroupId"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = 20 # Long polling: fewer empty receives, lower cost
  kms_master_key_id          = aws_kms_key.messaging.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# ------------------------------------------------------------------------------
# Order events: one topic, one queue per subscriber (fan-out)
# ------------------------------------------------------------------------------

resource "aws_sns_topic" "order_events" {
  name              = "${var.name}-order-events"
  kms_master_key_id = aws_kms_key.messaging.arn
}

resource "aws_sqs_queue" "subscriber_dlq" {
  for_each = toset(var.event_subscribers)

  name                      = "${var.name}-${each.key}-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.messaging.arn
}

resource "aws_sqs_queue" "subscriber" {
  for_each = toset(var.event_subscribers)

  name                       = "${var.name}-${each.key}"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = 20
  kms_master_key_id          = aws_kms_key.messaging.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.subscriber_dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })
}

# Each subscriber queue accepts messages only from the order-events topic
data "aws_iam_policy_document" "subscriber" {
  for_each = toset(var.event_subscribers)

  statement {
    sid       = "AllowOrderEventsTopic"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.subscriber[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.order_events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "subscriber" {
  for_each = toset(var.event_subscribers)

  queue_url = aws_sqs_queue.subscriber[each.key].id
  policy    = data.aws_iam_policy_document.subscriber[each.key].json
}

resource "aws_sns_topic_subscription" "subscriber" {
  for_each = toset(var.event_subscribers)

  topic_arn            = aws_sns_topic.order_events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.subscriber[each.key].arn
  raw_message_delivery = true # Subscribers receive the event itself, not an SNS envelope

  depends_on = [aws_sqs_queue_policy.subscriber]
}

# ------------------------------------------------------------------------------
# Alarm: anything in a DLQ is a message the system could not process
# ------------------------------------------------------------------------------

locals {
  dlq_names = merge(
    { orders = aws_sqs_queue.orders_dlq.name },
    { for k, q in aws_sqs_queue.subscriber_dlq : k => q.name },
  )
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each = local.dlq_names

  alarm_name          = "${var.name}-${each.key}-dlq-not-empty"
  alarm_description   = "Messages reached the ${each.key} dead-letter queue and need investigation"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_topic_arns
  ok_actions          = var.alarm_topic_arns

  dimensions = {
    QueueName = each.value
  }
}
