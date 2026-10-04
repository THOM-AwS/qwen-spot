variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "asg_name" {
  type = string
}

variable "uploader_asg_name" {
  type = string
}

variable "engine" {
  type = string
}

variable "ami_id" {
  type    = string
  default = null
}

variable "instance_types" {
  type = list(string)
}

variable "spot_max_price" {
  type = number
}

variable "max_instances" {
  type = number
}

variable "root_volume_size_gb" {
  type = number
}

variable "root_device_name" {
  description = "Root device of the worker AMI (DLAMI and Ubuntu use /dev/sda1)."
  type        = string
  default     = "/dev/sda1"
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "instance_profile_name" {
  type = string
}

variable "worker_config" {
  description = "Written verbatim to /etc/qwen-spot/config.env. Keys per docs/contract.md."
  type        = map(string)
}

variable "create_uploader" {
  type = bool
}

variable "uploader_instance_type" {
  type = string
}

variable "uploader_instance_profile" {
  type    = string
  default = null
}

variable "uploader_config" {
  description = "Written verbatim to /etc/qwen-spot/uploader.env."
  type        = map(string)
}

variable "upload_script_path" {
  description = "Path to scripts/upload_model.py, embedded in the uploader user data."
  type        = string
}

variable "uv_version" {
  description = "uv release the uploader installs. Bump uv_sha256 with it."
  type        = string
  default     = "0.12.23"
}

variable "uv_sha256" {
  description = "sha256 of uv-x86_64-unknown-linux-gnu.tar.gz for uv_version."
  type        = string
  default     = "9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6"
}
