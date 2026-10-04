output "instance_role_arn" {
  value = aws_iam_role.instance.arn
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.instance.name
}

output "uploader_role_arns" {
  description = "Empty when the uploader is disabled."
  value       = aws_iam_role.uploader[*].arn
}

output "uploader_instance_profile_name" {
  value = var.create_uploader ? aws_iam_instance_profile.uploader[0].name : null
}

output "client_policy_arn" {
  value = aws_iam_policy.client.arn
}
