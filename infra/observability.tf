# ==============================================================================
# OBSERVABILITY: VPC flow logs and service alarms
# ==============================================================================

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/vpc/${local.name}/flow-logs"
  retention_in_days = 30
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

# Rejected and accepted traffic for network forensics
resource "aws_flow_log" "vpc" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
}

# Alarms on the signals that matter to users: 5xx from targets and unhealthy hosts
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  for_each = {
    portfolio_api = aws_lb_target_group.portfolio_api.arn_suffix
    ai_service    = aws_lb_target_group.ai_service.arn_suffix
  }

  alarm_name          = "${local.name}-${each.key}-5xx"
  alarm_description   = "More than 10 target 5xx responses in 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = each.value
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  for_each = {
    portfolio_api = aws_lb_target_group.portfolio_api.arn_suffix
    ai_service    = aws_lb_target_group.ai_service.arn_suffix
  }

  alarm_name          = "${local.name}-${each.key}-unhealthy"
  alarm_description   = "At least one unhealthy target for 3 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = each.value
  }
}
