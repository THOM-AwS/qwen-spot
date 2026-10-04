variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "partition" {
  type = string
}

variable "weights_bucket_arn" {
  type = string
}

variable "results_bucket_arn" {
  type = string
}

variable "queue_arn" {
  type = string
}

variable "dlq_arn" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "asg_arn" {
  type = string
}

variable "uploader_asg_arn" {
  description = "null when the uploader is disabled."
  type        = string
  default     = null
}

variable "worker_log_group_arn" {
  type = string
}

variable "uploader_log_group_arn" {
  type = string
}

variable "allowed_cidrs" {
  type = list(string)
}

variable "client_user_names" {
  type = list(string)
}

variable "client_role_names" {
  type = list(string)
}

variable "create_uploader" {
  type = bool
}

variable "hf_token_ssm_parameter" {
  type = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for every role created here (see terraform/bootstrap)."
  type        = string
}
