locals {
  # Variable defaults can't reference other variables, so tags are merged
  # here instead of in var.tags's default.
  tags = merge(
    {
      environment = var.environment
      project     = var.project_name
    },
    var.tags
  )

  # Fills in a default AZ for subnets that don't pin one - keeps this
  # deployment single-AZ, since every ENI on an instance must share its AZ.
  default_az = data.aws_availability_zones.available.names[0]

  hub_subnets = { for k, v in var.hub_subnets : k => merge(v, { availability_zone = coalesce(v.availability_zone, local.default_az) }) }

  # TRex's spoofed client/server traffic ranges - matched here, not the
  # VPC's real subnet CIDRs, since that's what's actually in the packets.
  trex_client_subnet = "16.0.0.0/8"
  trex_server_subnet = "48.0.0.0/8"
}
