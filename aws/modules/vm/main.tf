# ==============================================================================
# EC2 Instance Module
# ==============================================================================
# Creates one or more ENIs (each with an optional Elastic IP and security
# groups) from var.network_interfaces, and an EC2 instance attached to all
# of them. Every network boundary is per-ENI - AWS has no subnet-level
# security groups. Windows isn't supported.

locals {
  # The primary=true entry (if any) goes first, landing at device_index 0.
  nic_keys_ordered = concat(
    [for key, nic in var.network_interfaces : key if nic.primary],
    [for key, nic in var.network_interfaces : key if !nic.primary]
  )

  # ENIs needing an auto-created management security group: public IP but
  # no explicit security group list.
  public_ip_nics_needing_management_sg = {
    for key, nic in var.network_interfaces : key => nic
    if nic.enable_public_ip && !contains(keys(var.security_group_ids), key)
  }
}

data "aws_ami" "this" {
  most_recent = true
  owners      = var.source_image.owners

  filter {
    name   = "name"
    values = [var.source_image.name_pattern]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "this" {
  count = var.admin_ssh_public_key != null ? 1 : 0

  key_name   = "${var.name}-key"
  public_key = var.admin_ssh_public_key
  tags       = var.tags

  lifecycle {
    precondition {
      condition     = var.admin_ssh_public_key != null || var.key_name != null
      error_message = "Either admin_ssh_public_key or key_name must be set - AWS Linux AMIs are provisioned via SSH key, not a password."
    }
  }
}

resource "aws_eip" "this" {
  for_each = { for key, nic in var.network_interfaces : key => nic if nic.enable_public_ip }

  domain            = "vpc"
  network_interface = aws_network_interface.this[each.key].id
  tags              = var.tags
}

# Allows only var.management_source_cidr in on SSH/RDP for public-IP ENIs
# without an explicit security group.
resource "aws_security_group" "management" {
  for_each = local.public_ip_nics_needing_management_sg

  name_prefix = "${var.name}-${each.key}-mgmt-"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-${each.key}-mgmt-sg" })

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.management_source_cidr]
  }

  ingress {
    description = "RDP"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.management_source_cidr]
  }

  # ingress/egress are fully authoritative for their direction - omitting
  # egress would leave no outbound rules at all.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    precondition {
      condition     = var.management_source_cidr != null
      error_message = "management_source_cidr must be set when a network_interfaces entry has enable_public_ip = true and no matching security_group_ids entry."
    }
  }
}

resource "aws_network_interface" "this" {
  for_each = var.network_interfaces

  subnet_id         = each.value.subnet_id
  private_ips       = each.value.private_ip_address != null ? [each.value.private_ip_address] : null
  source_dest_check = !each.value.disable_source_dest_check
  # lookup()'s third arg is a true default (unlike coalesce()); falls
  # through to null, leaving AWS's default SG in place.
  security_groups = lookup(
    var.security_group_ids, each.key,
    contains(keys(local.public_ip_nics_needing_management_sg), each.key) ? [aws_security_group.management[each.key].id] : null
  )
  tags = merge(var.tags, { Name = "${var.name}-${each.key}-eni" })
}

resource "aws_instance" "this" {
  ami           = data.aws_ami.this.id
  instance_type = var.instance_type
  key_name      = var.admin_ssh_public_key != null ? aws_key_pair.this[0].key_name : var.key_name
  tags          = var.tags

  # user_data_base64, not user_data - the latter re-encodes already-base64
  # data, double-encoding it and breaking bootstrap parsers expecting the
  # gzip'd payload directly.
  user_data_base64 = base64gzip(var.custom_data)

  # Forces replacement when custom_data changes - user-data otherwise only
  # runs on first boot.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = var.metadata_http_tokens
    http_endpoint = "enabled"
  }

  dynamic "cpu_options" {
    for_each = var.cpu_options != null ? [var.cpu_options] : []
    content {
      core_count       = cpu_options.value.core_count
      threads_per_core = cpu_options.value.threads_per_core
    }
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = var.root_volume_type
  }

  dynamic "network_interface" {
    for_each = local.nic_keys_ordered
    content {
      network_interface_id = aws_network_interface.this[network_interface.value].id
      device_index         = network_interface.key
    }
  }

  lifecycle {
    precondition {
      condition     = var.admin_ssh_public_key != null || var.key_name != null
      error_message = "Either admin_ssh_public_key or key_name must be set."
    }
  }
}
