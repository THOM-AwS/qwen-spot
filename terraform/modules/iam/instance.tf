data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name                 = "${var.name_prefix}-worker"
  assume_role_policy   = data.aws_iam_policy_document.ec2_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-worker"
  role = aws_iam_role.instance.name
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${var.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "ReadWeights"
    actions   = ["s3:GetObject"]
    resources = ["${var.weights_bucket_arn}/models/*", "${var.weights_bucket_arn}/cache/*"]
  }

  statement {
    sid       = "ListWeights"
    actions   = ["s3:ListBucket"]
    resources = [var.weights_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["models/*", "cache/*"]
    }
  }

  statement {
    sid       = "WriteCompileCache"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${var.weights_bucket_arn}/cache/*"]
  }

  # The worker reads its own earlier result (duplicate delivery, attempt count)
  # before writing a new one.
  statement {
    sid       = "ReadWriteResults"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.results_bucket_arn}/results/*"]
  }

  # Without ListBucket, S3 answers a GET for a missing key with AccessDenied
  # instead of 404, so the first lookup for every new request failed.
  statement {
    sid       = "ListResults"
    actions   = ["s3:ListBucket"]
    resources = [var.results_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["results/*", "requests/*"]
    }
  }

  statement {
    sid       = "ReadLargeRequests"
    actions   = ["s3:GetObject"]
    resources = ["${var.results_bucket_arn}/requests/*"]
  }

  statement {
    sid = "ConsumeQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [var.queue_arn]
  }

  statement {
    sid       = "UseKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }

  statement {
    sid       = "ScaleOwnGroup"
    actions   = ["autoscaling:SetDesiredCapacity"]
    resources = [var.asg_arn]
  }

  statement {
    sid       = "DescribeGroups"
    actions   = ["autoscaling:DescribeAutoScalingGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [var.worker_log_group_arn, "${var.worker_log_group_arn}:*"]
  }

  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["QwenSpot"]
    }
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${var.name_prefix}-worker"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}
