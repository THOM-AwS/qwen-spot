data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = data.aws_availability_zones.available.names
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name_prefix
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = var.name_prefix
  }
}

# Public subnets give instances outbound internet without a NAT gateway.
# Nothing is reachable inbound: the security group has no ingress rules.
resource "aws_subnet" "public" {
  for_each = { for i, az in local.azs : az => i }

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, each.value)
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${each.key}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.name_prefix}-public"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "worker" {
  name        = "${var.name_prefix}-worker"
  description = "No inbound. Shell access is SSM Session Manager only."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-worker"
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.worker.id
  description       = "All outbound (S3, SQS, SSM, Hugging Face)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# The default SG of a new VPC allows intra-SG traffic; strip it so nothing uses it by accident.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}

data "aws_iam_policy_document" "s3_endpoint" {
  statement {
    sid     = "ProjectBuckets"
    actions = ["s3:*"]
    resources = flatten([
      for b in var.bucket_names : ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"]
    ])

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid     = "SsmAgentBuckets"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::amazon-ssm-${data.aws_region.current.region}/*",
      "arn:aws:s3:::aws-ssm-${data.aws_region.current.region}/*",
      "arn:aws:s3:::amazon-ssm-packages-${data.aws_region.current.region}/*",
      "arn:aws:s3:::${data.aws_region.current.region}-birdwatcher-prod/*",
      "arn:aws:s3:::aws-ssm-document-attachments-${data.aws_region.current.region}/*",
      "arn:aws:s3:::patch-baseline-snapshot-${data.aws_region.current.region}/*",
      "arn:aws:s3:::amazoncloudwatch-agent-${data.aws_region.current.region}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]
  policy            = data.aws_iam_policy_document.s3_endpoint.json

  tags = {
    Name = "${var.name_prefix}-s3"
  }
}
