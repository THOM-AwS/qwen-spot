variable "weights_bucket" {
  type = string
}

variable "results_bucket" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "results_retention_days" {
  type = number
}

variable "weights_allowed_principal_arns" {
  description = "Principals exempt from the weights bucket data-plane deny."
  type        = list(string)
}

variable "results_allowed_principal_arns" {
  description = "Principals exempt from the results bucket data-plane deny."
  type        = list(string)
}

variable "listing_principal_arns" {
  description = "Principals that may list keys (Terraform's CI roles, for HeadBucket) but not read or write objects."
  type        = list(string)
  default     = []
}
