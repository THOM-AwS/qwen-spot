variable "name_prefix" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "alert_email" {
  type = string
}

variable "queue_name" {
  type = string
}

variable "dlq_name" {
  type = string
}

variable "asg_name" {
  type = string
}

variable "wake_policy_arn" {
  type = string
}

variable "max_uptime_hours" {
  type = number
}

variable "monthly_budget_usd" {
  type = number
}

variable "stuck_queue_seconds" {
  description = "Alert when the oldest message is older than this (usually: no spot capacity)."
  type        = number
  default     = 1200
}
