
# Caller's public IP - scopes management access to just this address.
data "http" "mgmt_from_public_ip" {
  url = "https://api.ipify.org?format=text"
}

# Feeds local.default_az, keeping every subnet single-AZ.
data "aws_availability_zones" "available" {
  state = "available"
}

# ==============================================================================
# Hub VPC
# ==============================================================================
# One VPC for everything, not the peered hub/spoke shape the Azure side uses
# - AWS VPC peering can't route through an appliance ENI in a different peered VPC.

module "hub" {
  source = "../../modules/network"

  name        = "vpc-${var.environment}-hub"
  cidr_blocks = var.hub_cidr_blocks
  tags        = local.tags

  subnets = local.hub_subnets
}

# ==============================================================================
# Routing - Hub
# ==============================================================================
# One route table per subnet. app-01/app-02 route both the real cross-subnet
# CIDR and TRex's spoofed range at FortiGate's single port2 ENI, which
# hairpins both directions back out itself onward to trex1/trex2.

module "hub_routing" {
  source = "../../modules/routing"

  name   = "rt-${var.environment}-hub"
  vpc_id = module.hub.vpc_id
  tags   = local.tags

  route_tables = {
    "firewall" = {
      subnet_ids = [module.hub.subnet_ids["firewall"]]
      routes = [
        {
          # trex client range -> back to trex1, which owns that spoofed
          # identity
          destination_cidr_block = local.trex_client_subnet
          target_type            = "network_interface"
          target_id              = module.vm_app_01.eni_ids["trex1"]
        },
        {
          # trex server range -> onward to trex2
          destination_cidr_block = local.trex_server_subnet
          target_type            = "network_interface"
          target_id              = module.vm_app_01.eni_ids["trex2"]
        },
        {
          # TRex data port 0 (client side) -> trex1
          destination_cidr_block = "21.0.0.0/29"
          target_type            = "network_interface"
          target_id              = module.vm_app_01.eni_ids["trex1"]
        },
        {
          # TRex data port 1 (client/server) -> trex2
          destination_cidr_block = "22.0.0.0/29"
          target_type            = "network_interface"
          target_id              = module.vm_app_01.eni_ids["trex2"]
        },
      ]
    }
    "mgmt" = {
      subnet_ids = [module.hub.subnet_ids["mgmt"]]
      routes = [
        {
          destination_cidr_block = "0.0.0.0/0"
          target_type            = "internet_gateway"
          target_id              = module.hub.internet_gateway_id
        },
      ]
    }
    "app-01" = {
      subnet_ids = [module.hub.subnet_ids["app-01"]]
      routes = [
        {
          # trex1 (app-01) -> FortiGate port2 (firewall) -> ... -> trex2
          destination_cidr_block = module.hub.subnet_cidr_blocks["app-02"]
          target_type            = "network_interface"
          target_id              = module.fortigate.port2_eni_id
        },
        {
          # trex1's actual outbound packets are addressed to the trex
          # server range, not app-02's real CIDR - same FortiGate port2,
          # just the destination TRex itself puts on the wire.
          destination_cidr_block = local.trex_server_subnet
          target_type            = "network_interface"
          target_id              = module.fortigate.port2_eni_id
        },
      ]
    }
    "app-02" = {
      subnet_ids = [module.hub.subnet_ids["app-02"]]
      routes = [
        {
          # trex2 (app-02) -> FortiGate port2 (firewall) -> ... -> trex1
          destination_cidr_block = module.hub.subnet_cidr_blocks["app-01"]
          target_type            = "network_interface"
          target_id              = module.fortigate.port2_eni_id
        },
        {
          # Mirror of app-01's extra route above, for the return direction.
          destination_cidr_block = local.trex_client_subnet
          target_type            = "network_interface"
          target_id              = module.fortigate.port2_eni_id
        },
      ]
    }
  }
}

# ==============================================================================
# EC2 Instances - trex
# ==============================================================================

# Allows TRex's spoofed client/server ranges in on trex1/trex2 - a
# pass-through; FortiOS's own firewall policy is the mechanism under test.
resource "aws_security_group" "trex_data" {
  name_prefix = "${var.project_name}-${var.environment}-trex-data-"
  vpc_id      = module.hub.vpc_id
  tags        = merge(local.tags, { Name = "${var.project_name}-${var.environment}-trex-data-sg" })

  ingress {
    description = "TRex client/server traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.trex_client_subnet, local.trex_server_subnet]
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

module "vm_app_01" {
  source = "../../modules/vm"

  name   = "${var.environment}-trex-01"
  vpc_id = module.hub.vpc_id

  network_interfaces = {
    # Shares the mgmt subnet with FortiGate's port1 (fortinet.tf).
    mgmt = {
      subnet_id          = module.hub.subnet_ids["mgmt"]
      private_ip_address = cidrhost(module.hub.subnet_cidr_blocks["mgmt"], 100)
      enable_public_ip   = true
      primary            = true
    }
    trex1 = {
      subnet_id                 = module.hub.subnet_ids["app-01"]
      private_ip_address        = cidrhost(module.hub.subnet_cidr_blocks["app-01"], 10)
      disable_source_dest_check = true
    }
    trex2 = {
      subnet_id                 = module.hub.subnet_ids["app-02"]
      private_ip_address        = cidrhost(module.hub.subnet_cidr_blocks["app-02"], 10)
      disable_source_dest_check = true
    }
  }

  security_group_ids = {
    trex1 = [aws_security_group.trex_data.id]
    trex2 = [aws_security_group.trex_data.id]
  }

  # No explicit SG for "mgmt" - auto-created, SSH only from this address.
  # /32 because AWS security group CIDRs don't accept a bare IP.
  management_source_cidr = "${trimspace(data.http.mgmt_from_public_ip.response_body)}/32"

  # c6in is the newer generation of c5n (Cisco's documented recommendation
  # for TRex-on-ENA testing).
  instance_type = "c6in.2xlarge"

  admin_ssh_public_key = var.vm_admin_ssh_public_key

  # Runs at first boot via cloud-init. Defaults to eth1/eth2 for the data NICs.
  custom_data = file("${path.module}/../../scripts/aws-trex-install.sh")

  tags = local.tags
}

# ==============================================================================
# DNS
# ==============================================================================
# A record per instance's public IP, named after the instance, in the
# pre-existing zone from var.dns_zone_id/dns_zone_name.

resource "aws_route53_record" "vm_app_01_dns_record" {
  zone_id = var.dns_zone_id
  name    = "${module.vm_app_01.name}.${var.dns_zone_name}"
  type    = "A"
  ttl     = 300
  records = [module.vm_app_01.public_ip_addresses["mgmt"]]
}

# A record for FortiGate's port1 Elastic IP.
resource "aws_route53_record" "fortigate_dns_record" {
  zone_id = var.dns_zone_id
  name    = "${module.fortigate.name}.${var.dns_zone_name}"
  type    = "A"
  ttl     = 300
  records = [module.fortigate.port1_public_ip]
}
