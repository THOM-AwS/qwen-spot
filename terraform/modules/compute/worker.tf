data "aws_ami_ids" "worker" {
  owners = ["self"]

  filter {
    name   = "tag:Project"
    values = ["qwen-spot"]
  }

  filter {
    name   = "tag:Engine"
    values = [var.engine]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  # aws_ami_ids sorts newest first. No AMI yet means no image: the group still
  # exists at desired 0, it just cannot launch until Packer has run.
  ami_id = var.ami_id != null ? var.ami_id : try(data.aws_ami_ids.worker.ids[0], null)

  # EC2 Auto Scaling refuses a group whose launch template has no image, so the
  # worker group (and its wake policy) exists only once a worker AMI does. Known
  # at plan time: the AMI lookup is a data source.
  worker_group_enabled = local.ami_id != null

  worker_user_data = templatefile("${path.module}/templates/worker-user-data.sh.tftpl", {
    config = var.worker_config
  })
}

resource "aws_launch_template" "worker" {
  name                   = "${var.name_prefix}-worker"
  image_id               = local.ami_id
  update_default_version = true
  user_data              = base64encode(local.worker_user_data)
  vpc_security_group_ids = [var.security_group_id]

  iam_instance_profile {
    name = var.instance_profile_name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = var.root_device_name

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size_gb
      iops                  = 6000
      throughput            = 500
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = false
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name    = "${var.name_prefix}-worker"
      Project = "qwen-spot"
      Role    = "worker"
    }
  }

  tag_specifications {
    resource_type = "volume"

    tags = {
      Name    = "${var.name_prefix}-worker"
      Project = "qwen-spot"
      Role    = "worker"
    }
  }
}

resource "aws_autoscaling_group" "worker" {
  count = local.worker_group_enabled ? 1 : 0

  name                      = var.asg_name
  min_size                  = 0
  max_size                  = var.max_instances
  desired_capacity          = 0
  vpc_zone_identifier       = var.worker_subnet_ids
  health_check_type         = "EC2"
  health_check_grace_period = 900
  capacity_rebalance        = false
  enabled_metrics           = ["GroupDesiredCapacity", "GroupInServiceInstances", "GroupPendingInstances", "GroupTotalInstances"]

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "price-capacity-optimized"
      spot_max_price                           = tostring(var.spot_max_price)
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.worker.id
        version            = "$Latest"
      }

      dynamic "override" {
        for_each = var.instance_types

        content {
          instance_type = override.value
        }
      }
    }
  }

  tag {
    key                 = "Project"
    value               = "qwen-spot"
    propagate_at_launch = true
  }

  lifecycle {
    # The client, the scale-out alarm and the worker own desired capacity.
    ignore_changes = [desired_capacity]
  }
}

# Backstop for a client that skipped its wake call: the queue alarm sets capacity to 1.
resource "aws_autoscaling_policy" "wake" {
  count = local.worker_group_enabled ? 1 : 0

  name                   = "${var.name_prefix}-wake"
  autoscaling_group_name = aws_autoscaling_group.worker[0].name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ExactCapacity"
  scaling_adjustment     = 1
  cooldown               = 60
}

# Used by the idle backstop alarm when the worker fails to scale itself in.
resource "aws_autoscaling_policy" "sleep" {
  count = local.worker_group_enabled ? 1 : 0

  name                   = "${var.name_prefix}-sleep"
  autoscaling_group_name = aws_autoscaling_group.worker[0].name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ExactCapacity"
  scaling_adjustment     = 0
  cooldown               = 60
}
