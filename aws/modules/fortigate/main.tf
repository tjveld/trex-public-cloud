# ==============================================================================
# FortiGate-VM64-AWS Module
# ==============================================================================
# Single-instance FortiGate NVA: a fixed port1 (external, public IP,
# auto-created HTTPS+SSH management SG)/port2 (internal, source_dest_check
# disabled) ENI pair via ../vm. port1 handles management/egress only; port2
# is the sole transit interface, hairpinning both directions back out itself.
#
# No equivalent of azurerm_marketplace_agreement - subscribing to the
# FortiGate-VM64-AWS listing is a manual, one-time step per account.

locals {
  # FortiGate's AWS marketplace image only picks up custom_data if wrapped
  # in this multipart MIME envelope - a bare CLI script is silently ignored.
  # replace(...) strips CRLF to LF, since AWS's bootstrap agent doesn't
  # tolerate embedded \r the way Azure's does.
  bootstrap_mime = var.bootstrap_config == null ? null : replace(<<-EOT
    Content-Type: multipart/mixed; boundary="==AWS=="
    MIME-Version: 1.0

    --==AWS==
    Content-Type: text/x-shellscript; charset="us-ascii"
    MIME-Version: 1.0

    ${var.bootstrap_config}

    --==AWS==--
  EOT
  , "\r\n", "\n")
}

# The vm module's auto-created SG only opens SSH/RDP - FortiOS's admin UI
# needs HTTPS too, so port1 gets an explicit SG here instead.
resource "aws_security_group" "management" {
  name_prefix = "${var.name}-mgmt-"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-mgmt-sg" })

  ingress {
    description = "HTTPS (FortiOS admin UI)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.management_source_cidr]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
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
}

module "vm" {
  source = "../vm"

  name   = var.name
  vpc_id = var.vpc_id

  network_interfaces = {
    port1 = {
      subnet_id          = var.port1_subnet_id
      private_ip_address = var.port1_private_ip_address
      enable_public_ip   = true
      primary            = true
    }
    port2 = {
      subnet_id                 = var.port2_subnet_id
      private_ip_address        = var.port2_private_ip_address
      disable_source_dest_check = true
    }
  }

  security_group_ids = merge(
    { port1 = [aws_security_group.management.id] },
    var.port2_security_group_ids != null ? { port2 = var.port2_security_group_ids } : {},
  )

  instance_type = var.instance_type
  source_image  = var.source_image

  admin_ssh_public_key = var.admin_ssh_public_key
  key_name             = var.key_name

  # local.bootstrap_mime wraps var.bootstrap_config in the MIME envelope
  # FortiGate's image requires.
  custom_data = local.bootstrap_mime

  # FortiOS's AWS bootstrap agent fetches user-data via an unauthenticated
  # IMDSv1-style GET, which the IMDSv2-required default silently blocks.
  metadata_http_tokens = "optional"

  root_volume_size = var.root_volume_size
  root_volume_type = var.root_volume_type

  tags = var.tags
}
