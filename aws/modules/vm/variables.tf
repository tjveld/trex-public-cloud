variable "name" {
  type        = string
  description = "Name of the EC2 instance. Also used to derive ENI/key pair/security group Name tags."
}

variable "vpc_id" {
  type        = string
  description = "VPC to create the auto-created management security group in."
}

variable "network_interfaces" {
  type = map(object({
    subnet_id                 = string
    private_ip_address        = optional(string)
    disable_source_dest_check = optional(bool, false)
    enable_public_ip          = optional(bool, false)
    primary                   = optional(bool, false)
  }))
  description = <<-EOT
    ENIs to create and attach, keyed by a short name (e.g. "mgmt", "trex1").
    When more than one entry is given, exactly one must have primary = true.
  EOT

  validation {
    condition     = length(var.network_interfaces) > 0
    error_message = "At least one network interface must be defined."
  }

  validation {
    condition     = length(var.network_interfaces) == 1 || length([for k, v in var.network_interfaces : k if v.primary]) == 1
    error_message = "When more than one network_interfaces entry is given, exactly one must have primary = true."
  }
}

variable "security_group_ids" {
  type        = map(list(string))
  description = "Map of network_interfaces key to security group IDs for that ENI. Omitted ENIs fall back to the auto-created management SG (if public) or the VPC default SG."
  default     = {}
}

variable "management_source_cidr" {
  type        = string
  description = "Source CIDR allowed to reach SSH/RDP. Required when a public network_interfaces entry has no matching security_group_ids entry."
  default     = null
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type, e.g. t3.micro"
  default     = "t3.micro"
}

variable "cpu_options" {
  type = object({
    core_count       = number
    threads_per_core = number
  })
  description = "Optional CPU core/thread override. Omit (default null) to leave AWS's default split for instance_type."
  default     = null
}

variable "source_image" {
  type = object({
    owners       = list(string)
    name_pattern = string
  })
  description = "AMI owner + name filter, resolved via the most recent match at plan time. Defaults to Canonical's official Ubuntu 22.04 LTS AMIs."
  default = {
    owners       = ["099720109477"]
    name_pattern = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
  }
}

variable "admin_ssh_public_key" {
  type        = string
  description = "SSH public key for the default AMI user, imported as a new key pair. Set this or key_name."
  default     = null
}

variable "key_name" {
  type        = string
  description = "Name of an existing EC2 key pair to use instead of importing admin_ssh_public_key."
  default     = null
}

variable "custom_data" {
  type        = string
  description = "Script or cloud-init config to run on first boot, as plain text - this module gzips/base64-encodes it."
  default     = null
}

variable "root_volume_size" {
  type        = number
  description = "Root EBS volume size, in GB"
  default     = 30
}

variable "root_volume_type" {
  type        = string
  description = "Root EBS volume type"
  default     = "gp3"
}

variable "metadata_http_tokens" {
  type        = string
  description = "IMDS HttpTokens setting. \"required\" enforces IMDSv2; some platform images' first-boot agents only support IMDSv1 and need \"optional\"."
  default     = "required"

  validation {
    condition     = contains(["required", "optional"], var.metadata_http_tokens)
    error_message = "metadata_http_tokens must be \"required\" or \"optional\"."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the instance and all ENIs/EIPs/security groups"
  default     = {}
}
