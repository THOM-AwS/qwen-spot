variable "region" {
  type        = string
  default     = "eu-north-1"
  description = "Region the AMI is built in. Must match the Terraform region."
}

variable "gpu_build_instance_type" {
  type        = string
  default     = "c7i.2xlarge"
  description = "Instance type for the gpu build. No GPU is needed to install vLLM; drivers only load at runtime on the H100."
}

variable "cpu_build_instance_type" {
  type        = string
  default     = "c7i.large"
  description = "Instance type for the cpu (end-to-end test) build."
}

variable "gpu_root_volume_gb" {
  type        = number
  default     = 100
  description = "Root volume for the gpu AMI. The DLAMI snapshot is 75 GB; the vLLM venv adds roughly 15 GB."
}

variable "cpu_root_volume_gb" {
  type        = number
  default     = 30
  description = "Root volume for the cpu AMI."
}

variable "kms_key_id" {
  type        = string
  default     = ""
  description = "KMS key for the AMI snapshot. Empty uses the AWS-managed EBS key."
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Subnet with outbound internet access. Empty uses the default VPC."
}

variable "security_group_id" {
  type        = string
  default     = ""
  description = "Existing security group with no inbound rules. Empty makes Packer create a temporary one that only admits 127.0.0.1/32."
}

variable "vllm_version" {
  type    = string
  default = "0.30.0"
}

variable "vllm_cpu_wheel_sha256" {
  type        = string
  default     = "0ee75278b3626c5d0b7c310c6d62afae93e900f4eac339c91e333fde5108ed78"
  description = "sha256 of vllm-<version>+cpu-cp38-abi3-manylinux_2_39_x86_64.whl from the vllm-project GitHub release."
}

variable "uv_version" {
  type    = string
  default = "0.12.23"
}

variable "uv_sha256" {
  type        = string
  default     = "9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6"
  description = "sha256 of uv-x86_64-unknown-linux-gnu.tar.gz."
}

variable "s5cmd_version" {
  type    = string
  default = "2.3.0"
}

variable "s5cmd_sha256" {
  type        = string
  default     = "de0fdbfa3aceae55e069ba81a0fc17b2026567637603734a387b2fca06c299b4"
  description = "sha256 of s5cmd_<version>_Linux-64bit.tar.gz."
}

variable "cwagent_gpg_fingerprint" {
  type        = string
  default     = "937616F3450B7D806CBD9725D58167303B789C72"
  description = "Fingerprint of the Amazon CloudWatch Agent signing key, as published in the AWS docs."
}
