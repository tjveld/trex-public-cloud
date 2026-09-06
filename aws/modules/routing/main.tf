# ==============================================================================
# Routing Module
# ==============================================================================
# Creates route tables, their routes, and their subnet associations for one
# VPC. One module instance per VPC; grouping of subnets under route_tables
# is entirely up to the caller.

resource "aws_route_table" "this" {
  for_each = var.route_tables

  vpc_id = var.vpc_id
  tags   = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

locals {
  # Flatten {rt_key => {routes = [...]}} into {"rt_key-idx" => route + rt_key}
  # for a static for_each key.
  routes = merge([
    for rt_key, rt in var.route_tables : {
      for idx, route in rt.routes : "${rt_key}-${idx}" => merge(route, { rt_key = rt_key })
    }
  ]...)

  # Flatten {rt_key => {subnet_ids = [...]}} into {"rt_key-idx" => association}.
  # Keyed by list index - subnet_id isn't known until apply.
  associations = merge([
    for rt_key, rt in var.route_tables : {
      for idx, subnet_id in rt.subnet_ids : "${rt_key}-${idx}" => { rt_key = rt_key, subnet_id = subnet_id }
    }
  ]...)
}

# target_type selects which of these arguments is actually set - aws_route
# allows exactly one target per route.
resource "aws_route" "this" {
  for_each = local.routes

  route_table_id         = aws_route_table.this[each.value.rt_key].id
  destination_cidr_block = each.value.destination_cidr_block

  gateway_id                = each.value.target_type == "internet_gateway" ? each.value.target_id : null
  nat_gateway_id            = each.value.target_type == "nat_gateway" ? each.value.target_id : null
  vpc_peering_connection_id = each.value.target_type == "peering_connection" ? each.value.target_id : null
  vpc_endpoint_id           = each.value.target_type == "vpc_endpoint" ? each.value.target_id : null
  network_interface_id      = each.value.target_type == "network_interface" ? each.value.target_id : null
  transit_gateway_id        = each.value.target_type == "transit_gateway" ? each.value.target_id : null
}

resource "aws_route_table_association" "this" {
  for_each = local.associations

  route_table_id = aws_route_table.this[each.value.rt_key].id
  subnet_id      = each.value.subnet_id
}
