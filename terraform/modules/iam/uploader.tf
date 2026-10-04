resource "aws_iam_role" "uploader" {
  count = var.create_uploader ? 1 : 0

  name                 = "${var.name_prefix}-uploader"
  assume_role_policy   = data.aws_iam_policy_document.ec2_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_instance_profile" "uploader" {
  count = var.create_uploader ? 1 : 0

  name = "${var.name_prefix}-uploader"
  role = aws_iam_role.uploader[0].name
}

resource "aws_iam_role_policy_attachment" "uploader_ssm" {
  count = var.create_uploader ? 1 : 0

  role       = aws_iam_role.uploader[0].name
  policy_arn = "arn:${var.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "uploader" {
  count = var.create_uploader ? 1 : 0

  statement {
    sid       = "WriteModels"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
    resources = ["${var.weights_bucket_arn}/models/*"]
  }

  statement {
    sid       = "ListModels"
    actions   = ["s3:ListBucket"]
    resources = [var.weights_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["models/*"]
    }
  }

  statement {
    sid       = "UseKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [var.uploader_log_group_arn, "${var.uploader_log_group_arn}:*"]
  }

  statement {
    sid       = "ScaleOwnGroup"
    actions   = ["autoscaling:SetDesiredCapacity"]
    resources = [coalesce(var.uploader_asg_arn, "arn:${var.partition}:autoscaling:${var.region}:${var.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.name_prefix}-uploader")]
  }

  dynamic "statement" {
    for_each = var.hf_token_ssm_parameter == "" ? [] : [var.hf_token_ssm_parameter]

    content {
      sid       = "ReadHfToken"
      actions   = ["ssm:GetParameter"]
      resources = ["arn:${var.partition}:ssm:${var.region}:${var.account_id}:parameter/${trimprefix(statement.value, "/")}"]
    }
  }

  dynamic "statement" {
    for_each = var.hf_token_ssm_parameter == "" ? [] : [1]

    content {
      sid       = "DecryptHfToken"
      actions   = ["kms:Decrypt"]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ssm.${var.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "uploader" {
  count = var.create_uploader ? 1 : 0

  name   = "${var.name_prefix}-uploader"
  role   = aws_iam_role.uploader[0].id
  policy = data.aws_iam_policy_document.uploader[0].json
}
