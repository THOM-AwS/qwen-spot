variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "bucket_names" {
  description = "Buckets the S3 gateway endpoint allows full access to."
  type        = list(string)
}
