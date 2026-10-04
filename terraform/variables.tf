# --- Placement and naming ---------------------------------------------------

variable "region" {
  description = "AWS region for every resource in this stack."
  type        = string
  default     = "eu-north-1"
}

variable "name_prefix" {
  description = "Prefix for resource names. IAM names must start with qwen-spot- for the CI role's IAM scope."
  type        = string
  default     = "qwen-spot"

  validation {
    condition     = can(regex("^qwen-spot(-[a-z0-9]{1,11})?$", var.name_prefix))
    error_message = "name_prefix must be qwen-spot or qwen-spot-<suffix>: the CI role and permissions boundary only cover qwen-spot-* names."
  }
}

# --- Compute ------------------------------------------------------------------

variable "instance_types" {
  description = "Spot instance types the ASG may launch. Each must fit the model."
  type        = list(string)
  default     = ["p5.4xlarge"]

  validation {
    condition     = length(var.instance_types) > 0
    error_message = "instance_types must contain at least one type."
  }
}

variable "spot_max_price" {
  description = "Spot price cap in USD/hr. Above this, nothing launches and requests wait in the queue."
  type        = number
  default     = 3.00

  validation {
    condition     = var.spot_max_price > 0
    error_message = "spot_max_price must be positive."
  }
}

variable "max_instances" {
  description = "ASG max size."
  type        = number
  default     = 1

  validation {
    condition     = var.max_instances >= 1 && var.max_instances <= 4
    error_message = "max_instances must be between 1 and 4."
  }
}

variable "engine" {
  description = "gpu for the H100 AMI, cpu for the cheap end-to-end test AMI."
  type        = string
  default     = "gpu"

  validation {
    condition     = contains(["gpu", "cpu"], var.engine)
    error_message = "engine must be gpu or cpu."
  }
}

variable "ami_id" {
  description = "Worker AMI. When null, the newest self-owned AMI tagged Project=qwen-spot and Engine=<engine> is used."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Worker root volume size. The DLAMI snapshot is 75 GB, so smaller is rejected."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_size_gb >= 75
    error_message = "root_volume_size_gb must be at least 75 (DLAMI snapshot size)."
  }
}

# --- Model and vLLM -----------------------------------------------------------

variable "model_repo" {
  description = "Hugging Face repo the uploader downloads."
  type        = string
  default     = "huihui-ai/Huihui-Qwen3.6-27B-abliterated"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.model_repo))
    error_message = "model_repo must be owner/name using letters, digits, dot, underscore or hyphen."
  }
}

variable "model_revision" {
  description = "Pinned Hugging Face commit SHA."
  type        = string
  default     = "27502c8717fd5a2f8c0c77188c10c243fd4f672e"

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.model_revision))
    error_message = "model_revision must be a full 40-char commit SHA."
  }
}

variable "model_name" {
  description = "Name vLLM serves the model under, and the S3 path component."
  type        = string
  default     = "qwen3.6-27b-abliterated"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]*$", var.model_name))
    error_message = "model_name must be lowercase letters, digits, dot, underscore or hyphen."
  }
}

variable "model_s3_uri" {
  description = "Override for the weights location. Default s3://<weights>/models/<model_name>/<model_revision>/."
  type        = string
  default     = null
}

variable "weight_load_mode" {
  description = "stream: vLLM runai_streamer from S3. copy: s5cmd to instance-store NVMe, then serve locally."
  type        = string
  default     = "stream"

  validation {
    condition     = contains(["stream", "copy"], var.weight_load_mode)
    error_message = "weight_load_mode must be stream or copy."
  }
}

variable "streamer_concurrency" {
  description = "runai_streamer S3 client concurrency."
  type        = number
  default     = 32
}

variable "max_model_len" {
  description = "vLLM --max-model-len."
  type        = number
  default     = 32768
}

variable "gpu_memory_utilization" {
  description = "vLLM --gpu-memory-utilization."
  type        = number
  default     = 0.92

  validation {
    condition     = var.gpu_memory_utilization > 0 && var.gpu_memory_utilization < 1
    error_message = "gpu_memory_utilization must be between 0 and 1."
  }
}

variable "vllm_extra_args" {
  description = "Extra space-separated vllm serve arguments."
  type        = string
  default     = ""

  # Written into a root-owned env file; keep shell metacharacters out.
  validation {
    condition     = !can(regex("[$`;|&<>\\\\\"'\n]", var.vllm_extra_args))
    error_message = "vllm_extra_args must not contain shell metacharacters ($ ` ; | & < > quotes, backslash, newline)."
  }
}

variable "compile_cache_enabled" {
  description = "Persist the vLLM torch.compile cache to S3 to shorten cold starts."
  type        = bool
  default     = true
}

# --- Worker -------------------------------------------------------------------

variable "idle_minutes" {
  description = "Minutes of empty queue with nothing in flight before the worker scales the group to 0."
  type        = number
  default     = 5

  validation {
    condition     = var.idle_minutes >= 1
    error_message = "idle_minutes must be at least 1."
  }
}

variable "worker_concurrency" {
  description = "Messages processed in parallel by the worker."
  type        = number
  default     = 8
}

variable "visibility_timeout_seconds" {
  description = "SQS visibility timeout. The worker extends it on a heartbeat while a job runs."
  type        = number
  default     = 900

  validation {
    condition     = var.visibility_timeout_seconds >= 60 && var.visibility_timeout_seconds <= 43200
    error_message = "visibility_timeout_seconds must be 60-43200."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention."
  type        = number
  default     = 14
}

# --- Storage ------------------------------------------------------------------

variable "results_retention_days" {
  description = "Days before results/ and requests/ objects expire."
  type        = number
  default     = 30
}

# --- Access -------------------------------------------------------------------

variable "client_principal_arns" {
  description = "IAM user/role ARNs allowed to assume the qwen-spot-client role. Only that role (plus the worker) can touch the queue and results; bucket and queue policies deny everyone else."
  type        = list(string)
  sensitive   = true

  validation {
    condition     = length(var.client_principal_arns) > 0 && alltrue([for a in var.client_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/[A-Za-z0-9+=,.@_/-]+$", a))])
    error_message = "client_principal_arns must be a non-empty list of IAM user or role ARNs. For an SSO role give the full path: arn:aws:iam::<acct>:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_<name>_<suffix>."
  }
}

variable "allowed_cidrs" {
  description = "When non-empty, client calls must come from these CIDRs (aws:SourceIp)."
  type        = list(string)
  default     = []
}

# --- Alerts and cost ----------------------------------------------------------

variable "alert_email" {
  description = "Email for alarms and the budget."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}

variable "max_uptime_hours" {
  description = "Alert when an instance has been in service this long."
  type        = number
  default     = 4

  validation {
    condition     = var.max_uptime_hours >= 1 && var.max_uptime_hours <= 24
    error_message = "max_uptime_hours must be 1-24 (CloudWatch evaluation window limit)."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget for resources tagged Project=qwen-spot."
  type        = number
  default     = 50
}

# --- Uploader -----------------------------------------------------------------

variable "create_uploader" {
  description = "Create the scale-to-zero uploader ASG that copies the model from Hugging Face to S3."
  type        = bool
  default     = true
}

variable "uploader_instance_type" {
  description = "On-demand uploader instance type. Needs instance-store NVMe for the download staging area."
  type        = string
  default     = "m5d.2xlarge"
}

variable "hf_token_ssm_parameter" {
  description = "Name of an existing SecureString parameter under /qwen-spot/ holding a Hugging Face token. Empty for ungated models. The permissions boundary only allows /qwen-spot/*."
  type        = string
  default     = ""

  validation {
    condition     = var.hf_token_ssm_parameter == "" || can(regex("^/qwen-spot/[A-Za-z0-9/_.-]+$", var.hf_token_ssm_parameter))
    error_message = "hf_token_ssm_parameter must be empty or a parameter name under /qwen-spot/ (letters, digits, / _ . -)."
  }
}

variable "admin_principal_arns" {
  description = "Break-glass IAM ARNs exempt from the bucket and queue data-plane denies (they still need IAM grants). Keep empty in normal use."
  type        = list(string)
  default     = []
  sensitive   = true

  validation {
    condition     = alltrue([for a in var.admin_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/[A-Za-z0-9+=,.@_/-]+$", a))])
    error_message = "admin_principal_arns must be IAM user or role ARNs."
  }
}

variable "permissions_boundary_arn" {
  description = "Boundary set on every role this stack creates. Default: the qwen-spot-boundary policy from terraform/bootstrap."
  type        = string
  default     = null
}

variable "max_receive_count" {
  description = "SQS receives before a message moves to the DLQ. Spot interruptions and releases use receives too, so this is a loose backstop above max_attempts."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 2 && var.max_receive_count <= 10
    error_message = "max_receive_count must be 2..10."
  }
}

variable "max_attempts" {
  description = "Generation failures the worker tolerates before writing a final error result. Keep below max_receive_count."
  type        = number
  default     = 3

  validation {
    condition     = var.max_attempts >= 1 && var.max_attempts <= 9
    error_message = "max_attempts must be 1..9."
  }
}

variable "create_autoscaling_service_linked_role" {
  description = "Create AWSServiceRoleForAutoScaling. Leave false where it already exists (any account that has used Auto Scaling); creating a duplicate fails."
  type        = bool
  default     = false
}
