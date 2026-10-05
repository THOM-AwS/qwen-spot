data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Every configured instance type must exist in the region. EC2 Auto Scaling does
# not reject an unoffered type up front; it just fails each launch, which looks
# like an empty queue that never drains.
locals {
  wanted_instance_types = distinct(concat(var.instance_types, var.create_uploader ? [var.uploader_instance_type] : []))
}

data "aws_ec2_instance_type_offerings" "available" {
  location_type = "region"

  filter {
    name   = "instance-type"
    values = local.wanted_instance_types
  }

  lifecycle {
    postcondition {
      condition     = length(setsubtract(local.wanted_instance_types, self.instance_types)) == 0
      error_message = "Instance types not offered in ${var.region}: ${join(", ", setsubtract(local.wanted_instance_types, self.instance_types))}."
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  # Roles created by terraform/bootstrap. Names are fixed there.
  ci_role_arns = [
    "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/qwen-spot-github-actions",
    "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/qwen-spot-github-plan",
  ]

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  # Created by terraform/bootstrap; the CI role refuses to create roles without it.
  permissions_boundary_arn = coalesce(var.permissions_boundary_arn, "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/qwen-spot-boundary")

  # Known before the ASGs exist, so user data and IAM can name them without a cycle.
  asg_name = "${var.name_prefix}-workers"
  # Pattern ARN: IAM scopes to the group by name, so policies do not depend on
  # the group existing (it is only created once a worker AMI exists).
  asg_arn           = "arn:${data.aws_partition.current.partition}:autoscaling:${var.region}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.name_prefix}-workers"
  uploader_asg_name = "${var.name_prefix}-uploader"

  weights_bucket = "${var.name_prefix}-weights-${random_id.suffix.hex}"
  results_bucket = "${var.name_prefix}-results-${random_id.suffix.hex}"

  model_s3_uri = coalesce(var.model_s3_uri, "s3://${local.weights_bucket}/models/${var.model_name}/${var.model_revision}/")
  compile_cache_s3_uri = (var.compile_cache_enabled
    ? "s3://${local.weights_bucket}/cache/vllm/${var.model_name}/${var.model_revision}/"
  : "")

  worker_log_group   = "/${var.name_prefix}/worker"
  uploader_log_group = "/${var.name_prefix}/uploader"
}

module "network" {
  source = "./modules/network"

  name_prefix  = var.name_prefix
  bucket_names = [local.weights_bucket, local.results_bucket]
}

module "iam" {
  source = "./modules/iam"

  name_prefix              = var.name_prefix
  region                   = var.region
  account_id               = local.account_id
  partition                = local.partition
  weights_bucket_arn       = module.storage.weights_bucket_arn
  results_bucket_arn       = module.storage.results_bucket_arn
  queue_arn                = module.queue.queue_arn
  dlq_arn                  = module.queue.dlq_arn
  kms_key_arn              = aws_kms_key.main.arn
  asg_arn                  = local.asg_arn
  uploader_asg_arn         = module.compute.uploader_asg_arn
  worker_log_group_arn     = aws_cloudwatch_log_group.worker.arn
  uploader_log_group_arn   = aws_cloudwatch_log_group.uploader.arn
  allowed_cidrs            = var.allowed_cidrs
  client_principal_arns    = var.client_principal_arns
  create_uploader          = var.create_uploader
  hf_token_ssm_parameter   = var.hf_token_ssm_parameter
  permissions_boundary_arn = local.permissions_boundary_arn
}

module "storage" {
  source = "./modules/storage"

  weights_bucket         = local.weights_bucket
  results_bucket         = local.results_bucket
  kms_key_arn            = aws_kms_key.main.arn
  results_retention_days = var.results_retention_days
  listing_principal_arns = local.ci_role_arns
  # Deny data-plane access to everyone else. Clients are listed on weights too so
  # the operator can inspect weights; their IAM policy still grants nothing there.
  weights_allowed_principal_arns = concat([module.iam.instance_role_arn], module.iam.uploader_role_arns, [module.iam.client_role_arn], var.admin_principal_arns)
  results_allowed_principal_arns = concat([module.iam.instance_role_arn, module.iam.client_role_arn], var.admin_principal_arns)
}

module "queue" {
  source = "./modules/queue"

  name_prefix                = var.name_prefix
  kms_key_arn                = aws_kms_key.main.arn
  visibility_timeout_seconds = var.visibility_timeout_seconds
  max_receive_count          = var.max_receive_count
  allowed_principal_arns     = concat([module.iam.instance_role_arn, module.iam.client_role_arn], var.admin_principal_arns)
}

module "compute" {
  source = "./modules/compute"

  name_prefix               = var.name_prefix
  region                    = var.region
  asg_name                  = local.asg_name
  uploader_asg_name         = local.uploader_asg_name
  engine                    = var.engine
  ami_id                    = var.ami_id
  instance_types            = [for t in var.instance_types : t if contains(data.aws_ec2_instance_type_offerings.available.instance_types, t)]
  spot_max_price            = var.spot_max_price
  max_instances             = var.max_instances
  root_volume_size_gb       = var.root_volume_size_gb
  subnet_ids                = module.network.subnet_ids
  security_group_id         = module.network.security_group_id
  kms_key_arn               = aws_kms_key.main.arn
  instance_profile_name     = module.iam.instance_profile_name
  uploader_instance_profile = module.iam.uploader_instance_profile_name
  create_uploader           = var.create_uploader
  uploader_instance_type    = var.uploader_instance_type
  upload_script_path        = "${path.root}/../scripts/upload_model.py"

  worker_config = {
    QWEN_REGION                 = var.region
    QWEN_QUEUE_URL              = module.queue.queue_url
    QWEN_RESULTS_BUCKET         = local.results_bucket
    QWEN_WEIGHTS_BUCKET         = local.weights_bucket
    QWEN_ASG_NAME               = local.asg_name
    QWEN_MODEL_S3_URI           = local.model_s3_uri
    QWEN_MODEL_NAME             = var.model_name
    QWEN_WEIGHT_LOAD_MODE       = var.weight_load_mode
    QWEN_STREAMER_CONCURRENCY   = tostring(var.streamer_concurrency)
    QWEN_MAX_MODEL_LEN          = tostring(var.max_model_len)
    QWEN_GPU_MEMORY_UTILIZATION = tostring(var.gpu_memory_utilization)
    QWEN_VLLM_EXTRA_ARGS        = trimspace("--max-num-seqs ${var.max_num_seqs} ${var.vllm_extra_args}")
    QWEN_ENGINE                 = var.engine
    QWEN_COMPILE_CACHE_S3_URI   = local.compile_cache_s3_uri
    QWEN_IDLE_MINUTES           = tostring(var.idle_minutes)
    QWEN_WORKER_CONCURRENCY     = tostring(var.worker_concurrency)
    QWEN_VISIBILITY_TIMEOUT     = tostring(var.visibility_timeout_seconds)
    QWEN_MAX_RECEIVE_COUNT      = tostring(var.max_receive_count)
    QWEN_MAX_ATTEMPTS           = tostring(var.max_attempts)
    QWEN_LOG_GROUP              = local.worker_log_group
  }

  uploader_config = {
    QWEN_REGION         = var.region
    QWEN_WEIGHTS_BUCKET = local.weights_bucket
    QWEN_MODEL_REPO     = var.model_repo
    QWEN_MODEL_REVISION = var.model_revision
    QWEN_MODEL_NAME     = var.model_name
    QWEN_HF_TOKEN_PARAM = var.hf_token_ssm_parameter
    QWEN_UPLOADER_ASG   = local.uploader_asg_name
    QWEN_WORK_DIR       = "/mnt/nvme"
    QWEN_LOG_GROUP      = local.uploader_log_group
  }
}

module "alarms" {
  source = "./modules/alarms"

  name_prefix           = var.name_prefix
  kms_key_arn           = aws_kms_key.main.arn
  alert_email           = var.alert_email
  queue_name            = module.queue.queue_name
  dlq_name              = module.queue.dlq_name
  asg_name              = module.compute.asg_name
  wake_policy_arn       = module.compute.wake_policy_arn
  worker_group_enabled  = module.compute.worker_group_enabled
  sleep_policy_arn      = module.compute.sleep_policy_arn
  idle_backstop_minutes = var.idle_backstop_minutes
  max_uptime_hours      = var.max_uptime_hours
  monthly_budget_usd    = var.monthly_budget_usd
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = local.worker_log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "uploader" {
  name              = local.uploader_log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}
