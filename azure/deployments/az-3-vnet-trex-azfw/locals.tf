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

  # TRex's spoofed client/server traffic ranges (distinct from VM subnet
  # addressing) - used as Azure Firewall rule addresses below.
  trex_client_subnet = "16.0.0.0/8"
  trex_server_subnet = "48.0.0.0/8"

  # Azure's own SNAT default, restated explicitly since setting
  # snat_private_ip_ranges (firewall.tf) replaces it rather than extending it.
  default_snat_private_ip_ranges = [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10",
  ]

  # Default for module "firewall"'s rule_collection_groups (used when
  # var.firewall_rule_collection_groups is null) - allows TRex client ->
  # server traffic; an empty policy denies everything by default.
  default_firewall_rule_collection_groups = [
    {
      name     = "clients-to-servers"
      priority = 500

      network_rule_collections = [
        {
          name     = "allow-clients-to-servers"
          action   = "Allow"
          priority = 100
          rules = [
            {
              # 80/443/8080/8081 duplicate allow-clients-http-https below,
              # so this traffic also matches at plain L4.
              name                  = "tcp-dataplane"
              protocols             = ["TCP"]
              source_addresses      = [local.trex_client_subnet]
              destination_addresses = [local.trex_server_subnet]
              destination_ports     = ["21", "23", "25", "80", "110", "443", "1494", "1521", "5003", "53", "445", "1935", "3306", "3389", "5432", "8080", "8081"]
            },
            {
              name                  = "udp-dataplane"
              protocols             = ["UDP"]
              source_addresses      = [local.trex_client_subnet]
              destination_addresses = [local.trex_server_subnet]
              destination_ports     = ["12", "53", "1212"]
            },
            {
              name                  = "icmp-latency"
              protocols             = ["ICMP"]
              source_addresses      = [local.trex_client_subnet]
              destination_addresses = [local.trex_server_subnet]
              destination_ports     = ["*"]
            },
            {
              # TRex's latency probes run over the VMs' real private IPs,
              # not the spoofed client/server ranges the rules above cover.
              name                  = "latency-dataplane"
              protocols             = ["TCP", "UDP", "ICMP"]
              source_addresses      = ["10.0.0.0/8"]
              destination_addresses = ["10.0.0.0/8"]
              destination_ports     = ["*"]
            },
          ]
        },
      ]

      # Application rules match FQDN, not IP - destination_fqdns = ["*"] is
      # the closest "any destination", scoped via source_addresses.
      application_rule_collections = [
        {
          name     = "allow-clients-http-https"
          action   = "Allow"
          priority = 200
          rules = [
            {
              name              = "http-https-app-layer"
              source_addresses  = [local.trex_client_subnet]
              destination_fqdns = ["*"]
              protocols = [
                { type = "Http", port = 80 },
                { type = "Https", port = 443 },
                { type = "Http", port = 8080 },
                { type = "Http", port = 8081 },
              ]
            },
          ]
        },
      ]
    },
  ]
}
