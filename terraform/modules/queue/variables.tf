variable "name_prefix" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "visibility_timeout_seconds" {
  type = number
}

variable "max_receive_count" {
  description = "Receives before a message moves to the dead-letter queue."
  type        = number
  default     = 3
}

variable "allowed_principal_arns" {
  description = "Principals exempt from the data-plane deny on both queues."
  type        = list(string)
}
