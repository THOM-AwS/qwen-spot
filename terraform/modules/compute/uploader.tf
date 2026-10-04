data "aws_ssm_parameter" "ubuntu" {
  count = var.create_uploader ? 1 : 0

  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  uploader_user_data = var.create_uploader ? templatefile("${path.module}/templates/uploader-user-data.sh.tftpl", {
    config        = var.uploader_config
    upload_script = file(var.upload_script_path)
    uv_version    = var.uv_version
    uv_sha256     = var.uv_sha256
    asg_name      = var.uploader_asg_name
    region        = var.region
  }) : ""
}

resource "aws_launch_template" "uploader" {
  count = var.create_uploader ? 1 : 0

  name                                 = "${var.name_prefix}-uploader"
  image_id                             = data.aws_ssm_parameter.ubuntu[0].insecure_value
  instance_type                        = var.uploader_instance_type
  update_default_version               = true
  user_data                            = base64gzip(local.uploader_user_data)
  vpc_security_group_ids               = [var.security_group_id]
  instance_initiated_shutdown_behavior = "terminate"

  iam_instance_profile {
    name = var.uploader_instance_profile
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_type           = "gp3"
      volume_size           = 30
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name    = "${var.name_prefix}-uploader"
      Project = "qwen-spot"
      Role    = "uploader"
    }
  }

  tag_specifications {
    resource_type = "volume"

    tags = {
      Name    = "${var.name_prefix}-uploader"
      Project = "qwen-spot"
      Role    = "uploader"
    }
  }

  lifecycle {
    precondition {
      # EC2 limits the decoded user data (here gzip) to 16 KB.
      condition     = length(base64gzip(local.uploader_user_data)) * 3 / 4 < 16384
      error_message = "Gzipped uploader user data must stay under 16 KB."
    }
  }
}

# On-demand and tiny: it runs once per model revision, then scales itself to 0.
resource "aws_autoscaling_group" "uploader" {
  count = var.create_uploader ? 1 : 0

  name                = var.uploader_asg_name
  min_size            = 0
  max_size            = 1
  desired_capacity    = 0
  vpc_zone_identifier = var.subnet_ids
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.uploader[0].id
    version = "$Latest"
  }

  tag {
    key                 = "Project"
    value               = "qwen-spot"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}
