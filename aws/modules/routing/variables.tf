variable "name" {
  type        = string
  description = "Name prefix for route tables created by this module, e.g. \"rt-dev-hub\"."
}

variable "vpc_id" {
  type        = string
  description = "VPC to create route tables in"
}

variable "route_tables" {
  type = map(object({
    subnet_ids = list(string)
    routes = optional(list(object({
      destination_cidr_block = string
      target_type            = string # one of: internet_gateway, nat_gateway, peering_connection, vpc_endpoint, network_interface, transit_gateway
      target_id              = string
    })), [])
  }))
  description = <<-EOT
    Route tables to create, keyed by a short name. Each entry's subnet_ids
    lists which subnets associate with that table; each route's target_type
    selects which target_id represents (e.g. "vpc_endpoint", "network_interface").
  EOT
  default     = {}

  validation {
    condition = alltrue(flatten([
      for rt in var.route_tables : [
        for route in rt.routes : contains(
          ["internet_gateway", "nat_gateway", "peering_connection", "vpc_endpoint", "network_interface", "transit_gateway"],
          route.target_type
        )
      ]
    ]))
    error_message = "Each route's target_type must be one of: internet_gateway, nat_gateway, peering_connection, vpc_endpoint, network_interface, transit_gateway."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all route tables created by this module"
  default     = {}
}
