packer {
  required_version = ">= 1.14.0"
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.2"
    }
  }
}

locals {
  build_time = timestamp()
  stamp      = formatdate("YYYYMMDDhhmmss", local.build_time)

  # SSM core only: the build is driven over Session Manager, so the instance
  # never needs an inbound rule.
  ssm_actions = [
    "ssm:UpdateInstanceInformation",
    "ssmmessages:CreateControlChannel",
    "ssmmessages:CreateDataChannel",
    "ssmmessages:OpenControlChannel",
    "ssmmessages:OpenDataChannel",
    "ec2messages:AcknowledgeMessage",
    "ec2messages:DeleteMessage",
    "ec2messages:FailMessage",
    "ec2messages:GetEndpoint",
    "ec2messages:GetMessages",
    "ec2messages:SendReply",
  ]

  common_tags = {
    Project     = "qwen-spot"
    VllmVersion = var.vllm_version
    SourceAmi   = "{{ .SourceAMI }}"
    BuildTime   = local.build_time
  }
}

source "amazon-ebs" "gpu" {
  region        = var.region
  instance_type = var.gpu_build_instance_type
  ami_name      = "qwen-spot-gpu-${local.stamp}"

  source_ami_filter {
    filters = {
      name                = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04) *"
      architecture        = "x86_64"
      virtualization-type = "hvm"
      state               = "available"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.gpu_root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  communicator  = "ssh"
  ssh_username  = "ubuntu"
  ssh_interface = "session_manager"
  temporary_iam_instance_profile_policy_document {
    Version = "2012-10-17"
    Statement {
      Effect   = "Allow"
      Action   = local.ssm_actions
      Resource = ["*"]
    }
  }
  associate_public_ip_address           = true
  subnet_id                             = var.subnet_id == "" ? null : var.subnet_id
  security_group_id                     = var.security_group_id == "" ? null : var.security_group_id
  temporary_security_group_source_cidrs = ["127.0.0.1/32"]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  imds_support = "v2.0"

  encrypt_boot = true
  kms_key_id   = var.kms_key_id == "" ? null : var.kms_key_id

  tags          = merge(local.common_tags, { Name = "qwen-spot-gpu-${local.stamp}", Engine = "gpu" })
  snapshot_tags = merge(local.common_tags, { Engine = "gpu" })
  run_tags      = { Project = "qwen-spot", Name = "qwen-spot-packer-gpu" }
}

source "amazon-ebs" "cpu" {
  region        = var.region
  instance_type = var.cpu_build_instance_type
  ami_name      = "qwen-spot-cpu-${local.stamp}"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      architecture        = "x86_64"
      virtualization-type = "hvm"
      state               = "available"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.cpu_root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  communicator  = "ssh"
  ssh_username  = "ubuntu"
  ssh_interface = "session_manager"
  temporary_iam_instance_profile_policy_document {
    Version = "2012-10-17"
    Statement {
      Effect   = "Allow"
      Action   = local.ssm_actions
      Resource = ["*"]
    }
  }
  associate_public_ip_address           = true
  subnet_id                             = var.subnet_id == "" ? null : var.subnet_id
  security_group_id                     = var.security_group_id == "" ? null : var.security_group_id
  temporary_security_group_source_cidrs = ["127.0.0.1/32"]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  imds_support = "v2.0"

  encrypt_boot = true
  kms_key_id   = var.kms_key_id == "" ? null : var.kms_key_id

  tags          = merge(local.common_tags, { Name = "qwen-spot-cpu-${local.stamp}", Engine = "cpu" })
  snapshot_tags = merge(local.common_tags, { Engine = "cpu" })
  run_tags      = { Project = "qwen-spot", Name = "qwen-spot-packer-cpu" }
}

build {
  name    = "qwen-spot"
  sources = ["source.amazon-ebs.gpu", "source.amazon-ebs.cpu"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/qwen-files /tmp/qwen-worker"]
  }

  provisioner "file" {
    source      = "${path.root}/files/"
    destination = "/tmp/qwen-files/"
  }

  provisioner "file" {
    source      = "${path.root}/../worker/"
    destination = "/tmp/qwen-worker/"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; sudo -E env {{ .Vars }} bash {{ .Path }}"
    environment_vars = [
      "ENGINE=${source.name}",
      "VLLM_VERSION=${var.vllm_version}",
      "VLLM_CPU_WHEEL_SHA256=${var.vllm_cpu_wheel_sha256}",
      "UV_VERSION=${var.uv_version}",
      "UV_SHA256=${var.uv_sha256}",
      "S5CMD_VERSION=${var.s5cmd_version}",
      "S5CMD_SHA256=${var.s5cmd_sha256}",
      "CWAGENT_GPG_FINGERPRINT=${var.cwagent_gpg_fingerprint}",
      "FILES_DIR=/tmp/qwen-files",
      "WORKER_SRC=/tmp/qwen-worker",
    ]
    scripts = [
      "${path.root}/files/install-base.sh",
      "${path.root}/files/install-vllm.sh",
      "${path.root}/files/install-worker.sh",
      "${path.root}/files/install-units.sh",
      "${path.root}/files/cleanup.sh",
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
  }
}
