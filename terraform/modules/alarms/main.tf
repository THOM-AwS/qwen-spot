resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# SQS metrics lag by a minute or more, and a queue idle for 6+ hours can take
# up to ~15 minutes to resume reporting. This alarm is the backstop; the client
# wake call is the fast path.
#
# Circuit breaker: it only wakes the group while the oldest message is younger
# than stuck_queue_seconds. Once requests have waited that long with nothing in
# flight, the stalled alarm below sets capacity to 0, and this alarm must not
# relaunch the same broken worker every minute. A client wake still works.
resource "aws_cloudwatch_metric_alarm" "scale_out" {
  count = var.worker_group_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-scale-out"
  alarm_description   = "Messages waiting (and not stuck): set worker capacity to 1."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.wake_policy_arn]

  metric_query {
    id          = "wake"
    expression  = "IF(FILL(visible, 0) >= 1 AND FILL(age, 0) < ${var.stuck_queue_seconds}, 1, 0)"
    label       = "Fresh messages waiting"
    return_data = true
  }

  metric_query {
    id = "visible"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      dimensions  = { QueueName = var.queue_name }
      stat        = "Maximum"
      period      = 60
    }
  }

  metric_query {
    id = "age"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateAgeOfOldestMessage"
      dimensions  = { QueueName = var.queue_name }
      stat        = "Maximum"
      period      = 60
    }
  }
}

# A worker that is up while requests wait and none is taken (vLLM never became
# healthy, the worker crashed). Nothing in flight, so a busy healthy worker is
# never stopped; in service, so a group that simply has no spot capacity is left
# to the stuck_queue email. Sets capacity to 0 and emails.
resource "aws_cloudwatch_metric_alarm" "stalled" {
  count = var.worker_group_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-stalled"
  alarm_description   = "Worker in service, requests waiting over ${var.stuck_queue_seconds / 60} min and none in flight: capacity set to 0. Check the vllm and worker logs."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.sleep_policy_arn, aws_sns_topic.alerts.arn]

  metric_query {
    id          = "stalled"
    expression  = "IF(FILL(inservice, 0) >= 1 AND FILL(age, 0) >= ${var.stuck_queue_seconds} AND FILL(inflight, 0) == 0, 1, 0)"
    label       = "In service, stuck queue, nothing in flight"
    return_data = true
  }

  metric_query {
    id = "inservice"
    metric {
      namespace   = "AWS/AutoScaling"
      metric_name = "GroupInServiceInstances"
      dimensions  = { AutoScalingGroupName = var.asg_name }
      stat        = "Maximum"
      period      = 60
    }
  }

  metric_query {
    id = "age"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateAgeOfOldestMessage"
      dimensions  = { QueueName = var.queue_name }
      stat        = "Maximum"
      period      = 60
    }
  }

  metric_query {
    id = "inflight"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesNotVisible"
      dimensions  = { QueueName = var.queue_name }
      stat        = "Maximum"
      period      = 60
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "stuck_queue" {
  alarm_name          = "${var.name_prefix}-stuck-queue"
  alarm_description   = "Oldest request waiting > ${var.stuck_queue_seconds / 60} min. Usually no spot capacity under the price cap."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = var.queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.stuck_queue_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  alarm_name          = "${var.name_prefix}-dead-letters"
  alarm_description   = "A request failed 3 times and is in the dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = var.dlq_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "uptime" {
  alarm_name          = "${var.name_prefix}-max-uptime"
  alarm_description   = "A worker has been in service for ${var.max_uptime_hours}h. Check it is not stuck awake."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = var.asg_name }
  statistic           = "Minimum"
  period              = 3600
  evaluation_periods  = var.max_uptime_hours
  datapoints_to_alarm = var.max_uptime_hours
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Filters on the Project tag, which must be activated as a cost allocation tag
# in Billing first or the budget sees nothing.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$qwen-spot"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# Backstop for the worker's own idle scale-in. Fires when an instance is in
# service while the queue has nothing waiting and nothing in flight for
# idle_backstop_minutes in a row, and then sets capacity to 0 and emails. It
# measures inactivity, not uptime, and does not depend on the worker being
# healthy. SQS stops publishing metrics for an idle queue, so missing queue
# data counts as empty (FILL 0); otherwise the alarm would go blind exactly
# when the queue is idle.
resource "aws_cloudwatch_metric_alarm" "idle_backstop" {
  count = var.worker_group_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-idle-backstop"
  alarm_description   = "Worker in service with an empty queue for ${var.idle_backstop_minutes} min: it did not scale itself in. Capacity set to 0."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = var.idle_backstop_minutes
  datapoints_to_alarm = var.idle_backstop_minutes
  # FILL already covers a missing SQS series. No data at all means no group
  # metrics either (nothing to scale in), so do not alarm on it.
  treat_missing_data = "notBreaching"
  alarm_actions      = [var.sleep_policy_arn, aws_sns_topic.alerts.arn]

  metric_query {
    id          = "idle"
    expression  = "IF(FILL(inservice, 0) >= 1 AND FILL(visible, 0) == 0 AND FILL(inflight, 0) == 0, 1, 0)"
    label       = "In service with an empty queue"
    return_data = true
  }

  metric_query {
    id = "inservice"
    metric {
      namespace   = "AWS/AutoScaling"
      metric_name = "GroupInServiceInstances"
      dimensions  = { AutoScalingGroupName = var.asg_name }
      stat        = "Maximum"
      period      = 60
    }
  }

  metric_query {
    id = "visible"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      dimensions  = { QueueName = var.queue_name }
      stat        = "Maximum"
      period      = 60
    }
  }

  metric_query {
    id = "inflight"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesNotVisible"
      dimensions  = { QueueName = var.queue_name }
      stat        = "Maximum"
      period      = 60
    }
  }
}
