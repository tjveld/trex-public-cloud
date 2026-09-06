# ==============================================================================
# General
# ==============================================================================

variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "eu-west-1"
}

variable "environment" {
  type        = string
  description = "Deployment environment name"
  default     = "aws-4"
}

variable "project_name" {
  type        = string
  description = "Project name for resource naming"
  default     = "trex"
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to all resources, merged with environment/project tags"
  default     = {}
}

variable "vm_admin_ssh_public_key" {
  type        = string
  description = "SSH public key for VMs in this configuration. No default - supply via *.auto.tfvars, -var, or TF_VAR_vm_admin_ssh_public_key."
}

# ==============================================================================
# Hub VPC
# ==============================================================================
# A single VPC - AWS VPC peering can't route through an appliance ENI in a
# different peered VPC, so the trex1 -> NVA -> trex2 path uses one VPC instead.

variable "hub_cidr_blocks" {
  type        = list(string)
  description = "CIDR block(s) for the VPC - first entry is primary, further entries are associated as secondary CIDR blocks."
  default     = ["10.10.0.0/16", "10.100.0.0/16"]
}

variable "hub_subnets" {
  type = map(object({
    cidr_block        = string
    availability_zone = optional(string)
  }))
  description = "VPC subnets. mgmt/app-01/app-02's CIDRs must match EXPECTED_IP1/EXPECTED_IP2 in aws/scripts/aws-trex-install.sh."
  default = {
    "mgmt" = {
      cidr_block = "10.10.0.0/24"
    }
    "app-01" = {
      cidr_block = "10.10.1.0/24"
    }
    "app-02" = {
      cidr_block = "10.10.2.0/24"
    }
    "firewall" = {
      cidr_block = "10.100.0.0/24"
    }
  }
}

# ==============================================================================
# FortiGate NVA
# ==============================================================================

variable "fortinet_source_image" {
  type = object({
    owners       = list(string)
    name_pattern = string
  })
  description = <<-EOT
    AMI owner + name filter for the FortiGate-VM64-AWS image, resolved to
    the most recent match. Owner 679593333241 is Fortinet's own AMI account.
  EOT
}

variable "fortinet_admin_username" {
  type        = string
  description = "Username for an additional FortiOS admin account created via bootstrap_config, alongside the built-in \"admin\" account (left untouched)."
  default     = "trex"
}

variable "fortinet_admin_password" {
  type        = string
  description = "Password for fortinet_admin_username's FortiOS admin account."
  sensitive   = true
}

variable "fortinet_instance_type" {
  type        = string
  description = <<-EOT
    EC2 instance type for the FortiGate NVA. Verify against the current
    FortiOS AWS deployment guide and the exact Marketplace listing subscribed to.
  EOT
  default     = "c8i.xlarge"
}

# ==============================================================================
# DNS
# ==============================================================================

variable "dns_zone_name" {
  type        = string
  description = "Name of the pre-existing Route 53 public hosted zone (e.g. aws.domain.com) that this deployment's A records are created in"
}

variable "dns_zone_id" {
  type        = string
  description = "ID of the pre-existing Route 53 public hosted zone that this deployment's A records are created in"
}

