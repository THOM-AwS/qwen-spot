output "region" {
  value = var.region
}

output "queue_url" {
  value = module.queue.queue_url
}

output "dlq_url" {
  value = module.queue.dlq_url
}

output "results_bucket" {
  value = local.results_bucket
}

output "weights_bucket" {
  value = local.weights_bucket
}

output "asg_name" {
  value = module.compute.asg_name
}

output "uploader_asg_name" {
  value = var.create_uploader ? local.uploader_asg_name : null
}

output "client_role_arn" {
  description = "Role qwenq assumes. Add an AWS profile with role_arn = this and source_profile = your profile."
  value       = module.iam.client_role_arn
}

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}

output "model_s3_uri" {
  value = local.model_s3_uri
}

output "log_group" {
  value = local.worker_log_group
}

output "sns_topic_arn" {
  value = module.alarms.sns_topic_arn
}

output "worker_ami_id" {
  description = "AMI the launch template uses. null means no AMI is built yet, so the group cannot launch."
  value       = module.compute.ami_id
}

output "client_config" {
  description = "Write to ~/.config/qwenq/config.json: terraform output -json client_config."
  value = {
    region         = var.region
    queue_url      = module.queue.queue_url
    dlq_url        = module.queue.dlq_url
    client_role    = module.iam.client_role_arn
    results_bucket = local.results_bucket
    asg_name       = module.compute.asg_name
    kms_key_arn    = aws_kms_key.main.arn
    instance_types = var.instance_types
    model_name     = var.model_name
  }
}

output "notes" {
  value = <<-EOT
    The budget filters on the tag Project=qwen-spot. Activate "Project" as a
    cost allocation tag once in Billing > Cost allocation tags, or the budget
    sees zero spend. Confirm the SNS email subscription sent to alert_email.
  EOT
}

output "model_name" {
  description = "Name vLLM serves the model as; also the weights bucket path component."
  value       = var.model_name
}

output "model_revision" {
  description = "Pinned Hugging Face commit the uploader fetches."
  value       = var.model_revision
}

output "instance_types" {
  value = var.instance_types
}

output "max_instances" {
  value = var.max_instances
}

output "uploader_log_group" {
  description = "The uploader ships its log here (one stream per instance id) before it scales itself to 0."
  value       = aws_cloudwatch_log_group.uploader.name
}
