# One customer-managed key for buckets, queues, SNS, logs and worker EBS volumes.

locals {
  kms_usage_principals = concat(
    [module.iam.instance_role_arn],
    module.iam.uploader_role_arns,
    [module.iam.client_role_arn],
  )

  # EC2 Auto Scaling encrypts launched volumes with this key through its service-linked role.
  autoscaling_slr_arn = "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
}

# The key policy names the EC2 Auto Scaling service-linked role, and KMS rejects a
# policy that names a principal that does not exist. The role already exists in
# any account that has used Auto Scaling (it does in the target account). Set
# create_autoscaling_service_linked_role = true for a fresh account.
resource "aws_iam_service_linked_role" "autoscaling" {
  count            = var.create_autoscaling_service_linked_role ? 1 : 0
  aws_service_name = "autoscaling.amazonaws.com"
}

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid = "Usage"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = local.kms_usage_principals
    }
  }

  statement {
    sid = "AutoScalingVolumes"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.autoscaling_slr_arn]
    }
  }

  statement {
    sid       = "AutoScalingVolumeGrants"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.autoscaling_slr_arn]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  statement {
    sid = "CloudWatchLogs"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/${var.name_prefix}/*"]
    }
  }

  statement {
    sid       = "CloudWatchAlarmsToSns"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "main" {
  description             = "${var.name_prefix} data key"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json

  depends_on = [aws_iam_service_linked_role.autoscaling]
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}
