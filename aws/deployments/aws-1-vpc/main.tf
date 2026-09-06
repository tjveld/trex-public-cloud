
# Caller's public IP - scopes management access to just this address.
data "http" "mgmt_from_public_ip" {
  url = "https://api.ipify.org?format=text"
}

# Feeds local.default_az, keeping every subnet single-AZ.
data "aws_availability_zones" "available" {
  state = "available"
}

# ==============================================================================
# VPC
# ==============================================================================

# Single VPC: mgmt/app-01/app-02/firewall subnets.
module "vpc" {
  source = "../../modules/network"

  name        = "vpc-${var.environment}"
  cidr_blocks = var.vpc_cidr_blocks
  tags        = local.tags

  subnets = local.vpc_subnets
}

# ==============================================================================
# Routing
# ==============================================================================
# One route table per subnet so each subnet's routing can be changed
# independently - same rationale as the Azure deployments.

module "vpc_routing" {
  source = "../../modules/routing"

  name   = "rt-${var.environment}"
  vpc_id = module.vpc.vpc_id
  tags   = local.tags

  route_tables = {
    for name, subnet_id in module.vpc.subnet_ids : name => {
      subnet_ids = [subnet_id]
      routes = [
        {
          destination_cidr_block = "0.0.0.0/0"
          target_type            = "internet_gateway"
          target_id              = module.vpc.internet_gateway_id
        },
      ]
    }
  }
}
