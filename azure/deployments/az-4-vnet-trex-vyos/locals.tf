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

  # Subnets with Azure route-table restrictions the generic per-vnet table
  # can't satisfy (Firewall, Gateway).
  reserved_subnet_names = [
    "AzureFirewallSubnet",
    "AzureFirewallManagementSubnet",
    "GatewaySubnet",
  ]

  # Flattens {subnet => {routes}} into {"subnet-route" => route} for a
  # static for_each key.
  spoke_1_subnet_routes = {
    for pair in flatten([
      for subnet_name, subnet in var.spoke_1_subnets : [
        for route in subnet.routes : merge(route, {
          key         = "${subnet_name}-${route.name}"
          subnet_name = subnet_name
        })
      ]
      if !contains(local.reserved_subnet_names, subnet_name)
    ]) : pair.key => pair
  }

  # VyOS's lan1 static IP - the next_hop_in_ip_address for spoke_1_subnets'
  # VirtualAppliance routes.
  vyos_lan1_ip = cidrhost(var.hub_subnets["firewall"].address_prefixes[0], 4)
}
