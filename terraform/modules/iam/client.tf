locals {
  source_ip_condition = length(var.allowed_cidrs) > 0 ? [{
    test     = "IpAddress"
    variable = "aws:SourceIp"
    values   = var.allowed_cidrs
  }] : []

  client_statements = {
    Submit = {
      actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
      resources = [var.queue_arn]
    }
    WatchDlq = {
      actions   = ["sqs:GetQueueAttributes"]
      resources = [var.dlq_arn]
    }
    ReadResults = {
      actions   = ["s3:GetObject"]
      resources = ["${var.results_bucket_arn}/results/*"]
    }
    ListResults = {
      actions   = ["s3:ListBucket"]
      resources = [var.results_bucket_arn]
    }
    WriteLargeRequests = {
      actions   = ["s3:PutObject"]
      resources = ["${var.results_bucket_arn}/requests/*"]
    }
    UseKey = {
      actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
      resources = [var.kms_key_arn]
    }
    WakeGroup = {
      actions   = ["autoscaling:SetDesiredCapacity"]
      resources = [var.asg_arn]
    }
    Describe = {
      actions = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeScalingActivities",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeInstances",
        "ssm:DescribeInstanceInformation",
      ]
      resources = ["*"]
    }
  }
}

data "aws_iam_policy_document" "client" {
  dynamic "statement" {
    for_each = local.client_statements

    content {
      sid       = statement.key
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = local.source_ip_condition

        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }

  # Port forwarding only. StartSession is checked against both the instance and
  # the session document. ssm:SessionDocumentAccessCheck = true makes SSM verify
  # the document against this policy, so the default interactive shell
  # (SSM-SessionManagerRunShell) is refused: it is not listed below. IAM cannot
  # restrict which port is forwarded; the SG and the 127.0.0.1 bind limit what
  # is reachable on the worker.
  statement {
    sid       = "PortForwardDocument"
    actions   = ["ssm:StartSession"]
    resources = ["arn:${var.partition}:ssm:${var.region}::document/AWS-StartPortForwardingSession"]

    condition {
      test     = "Bool"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }

    dynamic "condition" {
      for_each = local.source_ip_condition
      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
    }
  }

  statement {
    sid       = "SessionToWorker"
    actions   = ["ssm:StartSession"]
    resources = ["arn:${var.partition}:ec2:${var.region}:${var.account_id}:instance/*"]

    condition {
      test     = "Bool"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["worker"]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = ["qwen-spot"]
    }

    dynamic "condition" {
      for_each = local.source_ip_condition

      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
    }
  }

  statement {
    sid       = "OwnSessions"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:${var.partition}:ssm:*:*:session/*"]

    condition {
      test     = "StringLike"
      variable = "ssm:resourceTag/aws:ssmmessages:session-id"
      values   = ["$${aws:userid}"]
    }
  }
}

resource "aws_iam_policy" "client" {
  name        = "${var.name_prefix}-client"
  description = "Submit requests, read results, wake the group, tunnel to vLLM."
  policy      = data.aws_iam_policy_document.client.json
}

# Clients assume this role rather than having the policy attached to their user.
# The role carries the permissions boundary, so a later change to the client
# policy can never grant a human principal more than the boundary allows.
data "aws_iam_policy_document" "client_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.client_principal_arns
    }
  }
}

resource "aws_iam_role" "client" {
  name                 = "${var.name_prefix}-client"
  description          = "Assumed by qwenq to submit requests, read results, wake the group and tunnel."
  assume_role_policy   = data.aws_iam_policy_document.client_trust.json
  permissions_boundary = var.permissions_boundary_arn
  max_session_duration = 43200
}

resource "aws_iam_role_policy_attachment" "client" {
  role       = aws_iam_role.client.name
  policy_arn = aws_iam_policy.client.arn
}
