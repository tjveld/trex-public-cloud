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
  default     = "aws-3"
}

variable "project_name" {
  type        = string
  description = "Project name for resource naming"
  default     = "comp70046"
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
# A single VPC - a firewall endpoint with target_type = "vpc_endpoint" is
# AWS's own native pattern, so one VPC is the natural shape here.

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

