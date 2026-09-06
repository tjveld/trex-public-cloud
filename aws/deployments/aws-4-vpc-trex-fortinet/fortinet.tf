# ==============================================================================
# FortiGate NVA - Hub
# ==============================================================================
# FortiGate-VM64-AWS via ../../modules/fortigate: port1 (external, public IP,
# admin UI/API, shares the mgmt subnet) + port2 (internal, sole occupant of
# the firewall subnet, hairpins both trex1/trex2 traffic back out itself).
# No AWS equivalent of azurerm_marketplace_agreement - subscribing to the
# FortiGate-VM64-AWS listing remains a manual, one-time step per account.

# Allows TRex's spoofed client/server ranges in on port2 - a pass-through;
# FortiOS's own firewall policy is the mechanism under test.
resource "aws_security_group" "fortinet_data" {
  name_prefix = "${var.project_name}-${var.environment}-fortinet-data-"
  vpc_id      = module.hub.vpc_id
  tags        = merge(local.tags, { Name = "${var.project_name}-${var.environment}-fortinet-data-sg" })

  ingress {
    description = "TRex client/server traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.trex_client_subnet, local.trex_server_subnet]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# FortiGate-VM64-AWS + its port1/port2 ENIs.
module "fortigate" {
  source = "../../modules/fortigate"

  name   = "${var.environment}-fortinet-01"
  vpc_id = module.hub.vpc_id

  port1_subnet_id          = module.hub.subnet_ids["mgmt"]
  port1_private_ip_address = cidrhost(module.hub.subnet_cidr_blocks["mgmt"], 4)

  port2_subnet_id          = module.hub.subnet_ids["firewall"]
  port2_private_ip_address = cidrhost(module.hub.subnet_cidr_blocks["firewall"], 4)
  port2_security_group_ids = [aws_security_group.fortinet_data.id]

  # Auto-creates the port1 management security group (HTTPS+SSH), scoped to
  # this address.
  management_source_cidr = "${trimspace(data.http.mgmt_from_public_ip.response_body)}/32"

  instance_type = var.fortinet_instance_type
  source_image  = var.fortinet_source_image

  admin_ssh_public_key = var.vm_admin_ssh_public_key

  # Plain FortiOS CLI bootstrap - the module wraps it in the MIME envelope
  # FortiGate's AWS image requires. Its CLI body is deliberately comment-free
  # - `#` comments are suspected of making the first-boot parser reject the
  # entire script.
  bootstrap_config = templatefile("${path.module}/fgt-bootstrap.conf.tftpl", {
    wan_gateway    = cidrhost(module.hub.subnet_cidr_blocks["mgmt"], 1)
    port2_gateway  = cidrhost(module.hub.subnet_cidr_blocks["firewall"], 1)
    admin_username = var.fortinet_admin_username
    admin_password = var.fortinet_admin_password
  })

  tags = local.tags
}
