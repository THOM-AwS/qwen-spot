output "asg_name" {
  value = aws_autoscaling_group.worker.name
}

output "asg_arn" {
  value = aws_autoscaling_group.worker.arn
}

output "uploader_asg_arn" {
  value = var.create_uploader ? aws_autoscaling_group.uploader[0].arn : null
}

output "wake_policy_arn" {
  value = aws_autoscaling_policy.wake.arn
}

output "ami_id" {
  value = local.ami_id
}

output "launch_template_id" {
  value = aws_launch_template.worker.id
}
