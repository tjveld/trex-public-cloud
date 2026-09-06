variable "name" {
  type        = string
  description = "Name of the FortiGate EC2 instance. Also used to derive its ENIs, key pair, and management security group names."
}

variable "vpc_id" {
  type        = string
  description = "VPC to create the auto-created management security group in."
}

variable "port1_subnet_id" {
  type        = string
  description = "Subnet ID for port1 (external, public IP, management/egress only). Given device_index 0 (primary)."
}

variable "port1_private_ip_address" {
  type        = string
  description = "Static private IP for port1. Null (default) leaves it dynamically assigned."
  default     = null
}

variable "port2_subnet_id" {
  type        = string
  description = "Subnet ID for port2 (internal, source_dest_check disabled - the sole transit interface, including hairpinning)."
}

variable "port2_private_ip_address" {
  type        = string
  description = "Static private IP for port2. Null (default) leaves it dynamically assigned."
  default     = null
}

variable "management_source_cidr" {
  type        = string
  description = "Source CIDR allowed to reach port1 on HTTPS (443, admin UI) and SSH (22). Required - port1 always gets a public IP."
}

variable "port2_security_group_ids" {
  type        = list(string)
  description = "Security group IDs to attach to port2. Null (default) falls through to ../vm's default (the VPC default SG)."
  default     = null
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the FortiGate NVA. Verify sizing against the current FortiOS AWS deployment guide."
  default     = "c5.xlarge"
}

variable "source_image" {
  type = object({
    owners       = list(string)
    name_pattern = string
  })
  description = <<-EOT
    AMI owner + name filter for the FortiGate-VM64-AWS image, resolved to the
    most recent match. No default - only visible after subscribing on AWS
    Marketplace; resolve real values via `aws ec2 describe-images`.
  EOT
}

variable "admin_ssh_public_key" {
  type        = string
  description = "SSH public key for the FortiGate's default admin user, imported as a new key pair. Set this or key_name."
  default     = null
}

variable "key_name" {
  type        = string
  description = "Name of an existing EC2 key pair to use instead of importing admin_ssh_public_key."
  default     = null
}

variable "bootstrap_config" {
  type        = string
  description = <<-EOT
    Plain FortiOS CLI config script to run on first boot - this module wraps
    it in the MIME envelope FortiGate's AWS image requires. Null skips it.
  EOT
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

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the instance and all its ENIs/EIPs/security groups"
  default     = {}
}
