output "asg_name" {
  # The fixed name, so config, IAM and alarms do not depend on the group existing.
  value = var.asg_name
}

output "worker_group_enabled" {
  description = "False until a worker AMI exists."
  value       = local.worker_group_enabled
}


output "uploader_asg_arn" {
  value = var.create_uploader ? aws_autoscaling_group.uploader[0].arn : null
}

output "wake_policy_arn" {
  value = try(aws_autoscaling_policy.wake[0].arn, null)
}

output "ami_id" {
  value = local.ami_id
}

output "launch_template_id" {
  value = aws_launch_template.worker.id
}
