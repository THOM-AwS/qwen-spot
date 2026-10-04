# One-time stack: the GitHub Actions role the main stack's workflow assumes.
# Apply by hand with admin credentials (see README.md). Chicken and egg: CI
# cannot create the role it needs to run.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket and region: terraform init -backend-config=../backend.hcl
  backend "s3" {
    key          = "qwen-spot/bootstrap.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "qwen-spot"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "github_repo" {
  description = "owner/repo allowed to assume the role."
  type        = string
  default     = "THOM-AwS/qwen-spot"
}

variable "github_sub_prefix" {
  description = <<-EOT
    OIDC subject prefix GitHub issues for the repo. This repo uses immutable
    subjects (repo:<owner>@<owner_id>/<repo>@<repo_id>), so a renamed or
    re-registered repo name cannot take over the role. Read it with:
    gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
  EOT
  type        = string
  default     = "repo:THOM-AwS@48810100/qwen-spot@1403889323"

  validation {
    condition     = can(regex("^repo:[A-Za-z0-9-]+@[0-9]+/[A-Za-z0-9._-]+@[0-9]+$", var.github_sub_prefix))
    error_message = "github_sub_prefix must be the immutable form repo:<owner>@<id>/<repo>@<id>."
  }
}

variable "github_environment" {
  description = "GitHub environment the workflow runs in. The trust is pinned to it."
  type        = string
  default     = "aws"
}

variable "client_user_names" {
  description = "IAM users the main stack may attach the qwen-spot-client policy to. Empty means none."
  type        = list(string)
  default     = []
}

variable "state_bucket" {
  description = "S3 bucket holding Terraform state (the same one as in backend.hcl). CI gets access to its qwen-spot/ prefix."
  type        = string
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  p          = data.aws_partition.current.partition
  iam_arn    = "arn:${local.p}:iam::${local.account_id}"
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_sub_prefix}:environment:${var.github_environment}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "qwen-spot-github-actions"
  description          = "Terraform plan/apply for ${var.github_repo}"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# ---- permissions boundary ---------------------------------------------------
# Every role the main stack creates must carry this boundary (enforced below on
# iam:CreateRole). Whatever policy CI attaches to a qwen-spot-* role, the role can
# never exceed what the worker and uploader actually use.

data "aws_iam_policy_document" "boundary" {
  # Data plane is limited to qwen-spot-* resources: a role CI creates must never
  # reach other buckets in this account (Terraform state for other stacks lives here).
  statement {
    sid = "ProjectBuckets"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucket",
    ]
    resources = [
      "arn:${local.p}:s3:::qwen-spot-*",
      "arn:${local.p}:s3:::qwen-spot-*/*",
    ]
  }

  statement {
    sid = "ProjectQueues"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:SendMessage",
    ]
    resources = ["arn:${local.p}:sqs:*:${local.account_id}:qwen-spot-*"]
  }

  statement {
    sid       = "ProjectKeys"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = ["arn:${local.p}:kms:*:${local.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["qwen-spot"]
    }
  }

  # SecureString parameters under /qwen-spot/ use the AWS-managed SSM key.
  statement {
    sid       = "SsmManagedKeyViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["arn:${local.p}:kms:*:${local.account_id}:key/*"]

    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["ssm.*.amazonaws.com"]
    }
  }

  statement {
    sid       = "ProjectParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.p}:ssm:*:${local.account_id}:parameter/qwen-spot/*"]
  }

  statement {
    sid       = "ProjectGroups"
    actions   = ["autoscaling:SetDesiredCapacity"]
    resources = ["arn:${local.p}:autoscaling:*:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/qwen-spot-*"]
  }

  statement {
    sid       = "ProjectLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["arn:${local.p}:logs:*:${local.account_id}:log-group:/qwen-spot/*"]
  }

  # Read-only describes and the SSM agent channel have no resource-level scoping.
  statement {
    sid = "AgentAndDescribe"
    actions = [
      "autoscaling:Describe*",
      "logs:DescribeLogGroups",
      "cloudwatch:PutMetricData",
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "ec2messages:*",
      "ssmmessages:*",
      "ssm:UpdateInstanceInformation",
      "ssm:ListAssociations",
      "ssm:ListInstanceAssociations",
      "ssm:DescribeAssociation",
      "ssm:DescribeDocument",
      "ssm:GetDocument",
      "ssm:GetDeployablePatchSnapshotForInstance",
      "ssm:GetManifest",
      "ssm:PutComplianceItems",
      "ssm:PutConfigurePackageResult",
      "ssm:PutInventory",
      "ssm:UpdateAssociationStatus",
      "ssm:UpdateInstanceAssociationStatus",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "NeverEscalate"
    effect = "Deny"
    actions = [
      "iam:*",
      "organizations:*",
      "account:*",
      "sso:*",
      "sts:AssumeRole",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = "qwen-spot-boundary"
  description = "Permissions boundary required on every qwen-spot-* role"
  policy      = data.aws_iam_policy_document.boundary.json
}

# ---- CI role ------------------------------------------------------------------

locals {
  ci_role_arn  = "${local.iam_arn}:role/qwen-spot-github-actions"
  boundary_arn = "${local.iam_arn}:policy/qwen-spot-boundary"
  # Policies CI may attach. The SSM core policy is the only AWS-managed one.
  attachable_policies = [
    "${local.iam_arn}:policy/qwen-spot-*",
    "arn:${local.p}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]
  role_write_actions = [
    "iam:DeleteRole",
    "iam:UpdateRole",
    "iam:UpdateRoleDescription",
    "iam:TagRole",
    "iam:UntagRole",
    "iam:PutRolePolicy",
    "iam:DeleteRolePolicy",
  ]
}

data "aws_iam_policy_document" "iam_scoped" {
  statement {
    sid       = "CreateRolesWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = ["${local.iam_arn}:role/qwen-spot-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid       = "ManageProjectRoles"
    actions   = local.role_write_actions
    resources = ["${local.iam_arn}:role/qwen-spot-*"]
  }

  statement {
    sid       = "AttachAllowedPoliciesToRoles"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["${local.iam_arn}:role/qwen-spot-*"]

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values   = local.attachable_policies
    }
  }

  statement {
    sid = "ManageProjectPolicies"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = ["${local.iam_arn}:policy/qwen-spot-*"]
  }

  statement {
    sid = "ManageInstanceProfiles"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["${local.iam_arn}:instance-profile/qwen-spot-*"]
  }

  statement {
    sid = "ReadIam"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:ListEntitiesForPolicy",
      "iam:GetInstanceProfile",
      "iam:GetUser",
      "iam:ListAttachedUserPolicies",
      "iam:GetOpenIDConnectProvider",
    ]
    resources = ["*"]
  }

  # PassRole only to EC2: instance profiles in launch templates.
  statement {
    sid       = "PassProjectRolesToEc2"
    actions   = ["iam:PassRole"]
    resources = ["${local.iam_arn}:role/qwen-spot-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["autoscaling.amazonaws.com", "spot.amazonaws.com"]
    }
  }

  # The main stack attaches the client policy to named operator users only.
  dynamic "statement" {
    for_each = length(var.client_user_names) > 0 ? [1] : []
    content {
      sid       = "AttachClientPolicyToUsers"
      actions   = ["iam:AttachUserPolicy", "iam:DetachUserPolicy"]
      resources = [for u in var.client_user_names : "${local.iam_arn}:user/${u}"]

      condition {
        test     = "ArnEquals"
        variable = "iam:PolicyARN"
        values   = ["${local.iam_arn}:policy/qwen-spot-client"]
      }
    }
  }

  # ---- explicit denies: CI can never widen its own reach -------------------

  statement {
    sid         = "DenyTouchingOwnRole"
    effect      = "Deny"
    not_actions = ["iam:Get*", "iam:List*"]
    resources   = [local.ci_role_arn]
  }

  statement {
    sid    = "DenyEditingBoundary"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [local.boundary_arn]
  }

  # Trust policies change only through this bootstrap stack, applied by a human.
  # Otherwise CI could make a project role trust an outside account.
  statement {
    sid       = "DenyTrustPolicyEdits"
    effect    = "Deny"
    actions   = ["iam:UpdateAssumeRolePolicy"]
    resources = ["*"]
  }

  statement {
    sid       = "DenyRemovingBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }

  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:${local.p}:s3:::${var.state_bucket}/qwen-spot/*"]
  }

  statement {
    sid       = "StateBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.p}:s3:::${var.state_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["qwen-spot/*"]
    }
  }
}

resource "aws_iam_role_policy" "iam_scoped" {
  name   = "qwen-spot-iam-scoped"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.iam_scoped.json
}

# Service allowlist, replacing PowerUserAccess. This is the management account,
# so everything is scoped to qwen-spot-* names or the Project tag where the
# service supports it, and cross-account and org-level actions are denied.
data "aws_iam_policy_document" "services" {
  statement {
    sid       = "Ec2AndAutoScaling"
    actions   = ["ec2:*", "autoscaling:*"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # Nothing in the stack copies, shares or exports disks and images, or swaps
  # instance roles. These would let CI read or hijack other workloads.
  statement {
    sid    = "DenyEc2Exfiltration"
    effect = "Deny"
    actions = [
      "ec2:ModifySnapshotAttribute",
      "ec2:ModifyImageAttribute",
      "ec2:ModifyInstanceAttribute",
      "ec2:AssociateIamInstanceProfile",
      "ec2:ReplaceIamInstanceProfileAssociation",
      "ec2:GetPasswordData",
      "ec2:CreateSnapshot",
      "ec2:CreateSnapshots",
      "ec2:CopySnapshot",
      "ec2:CopyImage",
      "ec2:CreateImage",
      "ec2:ExportImage",
      "ec2:CreateInstanceExportTask",
      "ec2:CreateStoreImageTask",
      "ec2:EnableSerialConsoleAccess",
    ]
    resources = ["*"]
  }

  # Changing or deleting existing EC2 and Auto Scaling resources needs the
  # project tag. Creates are allowed (new resources carry the tag via default_tags).
  statement {
    sid    = "DenyForeignEc2Changes"
    effect = "Deny"
    actions = [
      "ec2:TerminateInstances",
      "ec2:StopInstances",
      "ec2:StartInstances",
      "ec2:RebootInstances",
      "ec2:AttachVolume",
      "ec2:DetachVolume",
      "ec2:DeleteVolume",
      "ec2:ModifyLaunchTemplate",
      "ec2:CreateLaunchTemplateVersion",
      "ec2:DeleteLaunchTemplate",
      "ec2:DeleteLaunchTemplateVersions",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
      "ec2:DeleteSecurityGroup",
      "ec2:CreateRoute",
      "ec2:ReplaceRoute",
      "ec2:DeleteRoute",
      "ec2:DeleteRouteTable",
      "ec2:DeleteSubnet",
      "ec2:DeleteVpc",
      "ec2:DeleteInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:ModifyVpcEndpoint",
      "ec2:DeleteVpcEndpoints",
      "ec2:DeleteTags",
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["qwen-spot"]
    }
  }

  # Tagging an existing foreign resource Project=qwen-spot would sidestep the
  # guard above, so tags on existing resources need the tag already.
  statement {
    sid       = "DenyRetaggingForeignEc2"
    effect    = "Deny"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "ec2:CreateAction"
      values   = ["true"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["qwen-spot"]
    }
  }

  statement {
    sid    = "DenyForeignAutoScalingChanges"
    effect = "Deny"
    actions = [
      "autoscaling:UpdateAutoScalingGroup",
      "autoscaling:DeleteAutoScalingGroup",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:PutScalingPolicy",
      "autoscaling:DeletePolicy",
      "autoscaling:CreateOrUpdateTags",
      "autoscaling:DeleteTags",
      "autoscaling:AttachInstances",
      "autoscaling:DetachInstances",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:SetInstanceProtection",
      "autoscaling:PutLifecycleHook",
      "autoscaling:DeleteLifecycleHook",
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "autoscaling:ResourceTag/Project"
      values   = ["qwen-spot"]
    }
  }

  statement {
    sid       = "Queues"
    actions   = ["sqs:*"]
    resources = ["arn:${local.p}:sqs:*:${local.account_id}:qwen-spot-*"]
  }

  statement {
    sid       = "Topics"
    actions   = ["sns:*"]
    resources = ["arn:${local.p}:sns:*:${local.account_id}:qwen-spot-*"]
  }

  statement {
    sid     = "Buckets"
    actions = ["s3:*"]
    resources = [
      "arn:${local.p}:s3:::qwen-spot-*",
      "arn:${local.p}:s3:::qwen-spot-*/*",
    ]
  }

  statement {
    sid = "KeyCreate"
    actions = [
      "kms:CreateKey",
      "kms:TagResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = ["qwen-spot"]
    }
  }

  statement {
    sid       = "KeyManage"
    actions   = ["kms:*"]
    resources = ["arn:${local.p}:kms:*:${local.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["qwen-spot"]
    }
  }

  statement {
    sid       = "KeyAliases"
    actions   = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
    resources = ["arn:${local.p}:kms:*:${local.account_id}:alias/qwen-spot*"]
  }

  statement {
    sid       = "LogGroups"
    actions   = ["logs:*"]
    resources = ["arn:${local.p}:logs:*:${local.account_id}:log-group:/qwen-spot/*"]
  }

  statement {
    sid       = "Alarms"
    actions   = ["cloudwatch:*"]
    resources = ["arn:${local.p}:cloudwatch:*:${local.account_id}:alarm:qwen-spot-*"]
  }

  statement {
    sid       = "Budget"
    actions   = ["budgets:*"]
    resources = ["arn:${local.p}:budgets::${local.account_id}:budget/qwen-spot-*"]
  }

  statement {
    sid       = "PublicParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.p}:ssm:*::parameter/aws/service/*"]
  }

  statement {
    sid = "AccountWideReads"
    actions = [
      "sts:GetCallerIdentity",
      "tag:GetResources",
      "s3:ListAllMyBuckets",
      "sqs:ListQueues",
      "sns:ListTopics",
      "kms:ListKeys",
      "kms:ListAliases",
      "logs:DescribeLogGroups",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListTagsForResource",
      "budgets:ViewBudget",
      "budgets:DescribeBudgetActionsForAccount",
      "ssm:DescribeParameters",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyOrgAndCrossAccount"
    effect = "Deny"
    actions = [
      "sts:AssumeRole",
      "organizations:*",
      "account:*",
      "sso:*",
      "sso-directory:*",
      "identitystore:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "services" {
  name   = "qwen-spot-services"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.services.json
}

output "role_arn" {
  description = "Set as the AWS_ROLE_ARN variable on the GitHub environment 'aws'."
  value       = aws_iam_role.github_actions.arn
}

output "permissions_boundary_arn" {
  description = "Boundary every qwen-spot-* role must carry. The main stack sets it."
  value       = aws_iam_policy.boundary.arn
}

# The main stack's budget filters on user:Project. Billing ignores a tag until it
# is activated as a cost allocation tag. This is account-wide: every project's
# Project tag becomes filterable in Cost Explorer and Budgets.
resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "Project"
  status  = "Active"
}
